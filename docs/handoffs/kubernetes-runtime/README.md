# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S5.3b `IN_PROGRESS`；S5.4a、S5.4b、S5.4c 均为 `DONE`。普通启动的 worker 架构与 E2E
入口性能门禁已经关闭，当前只在该 worker 快路径上收口 Kubernetes v1.36.4 官方
NodeConformance。RuntimeTemplate、PodSnapshot 和 Pause/Resume 保持延期到 S5.3c 完成后的
S6.1，不阻塞本轮 E2E。

## 基线

最后验证实现为 `fa278467d5bf7100eadd3a3004b19446f87d6dcb`，tree 为
`d118d11a2a0ff4074458a7c3ecb795e03f2eb85a`。W2 已部署该版本；Shim/worker/runtime SHA-256
分别为 `dbb52f29…`、`693ecffd…`、`9aac8c8d…`，回滚目录为
`/opt/cubesandbox-s0-multinode-runtime-2269a3b3/backups/s54-fastpath-20260904T211438Z`。
W1 仍是上一版 `94c01e21` 三个 runtime 二进制，PVM Guest kernel SHA-256 为 `633bb982…`；
部署 S5.3b 候选时必须保留 W1 的 Agent、kernel 和既有回滚副本，只替换三个 runtime 二进制。

## 已完成

S0、S1、S2、S3.1～S3.4d、S5.4a～S5.4c 已完成。S5.4b 把 VMM、vCPU、virtiofs 和 Guest
memory 拆入每 Pod 一个 `cube-vmm-worker`，并通过双节点、多容器、restart、kill、cancel、
embedded rollback 与 exact-zero。S5.4c 把正常 Pod 启动的 `systemctl show` 从 264 次降到 0；
串行 50/50 的 PodScheduled→Ready P95 为 1935.438ms、RunPodSandbox P95 为 1575.632ms，
5×10 并发为 50/50，全部 PullImage=0。restart、worker/Shim SIGKILL 和 5 Pod 创建取消后均
exact-zero。同一 reviewer `PASS`，P0/P1/P2=0/0/1；完整证据见
[S5.4b](./evidence/s5.4/s5.4b-worker-split.md) 与
[S5.4c](./evidence/s5.4/s5.4c-startup-fastpath.md)。

## 未完成

S5.3b 需要在 W1 部署 `fa278467` 后，把官方 NodeConformance 拆成有界 shard 全部执行，并将
支持面缺陷、明确不支持项、runner/环境问题分开。上一轮 full-4 在 6 小时 timeout 前执行
398/477：357 Passed、41 Failed、79 未执行；这只是旧路径基线，不能作为最终结果。已知首个
缺口是 Guest 缺少 `/etc/hostname`（`K8S-OQ-033`）；另有 tmpfs mount identity、host namespace、
私有镜像、stats/metrics、网络、sidecar、CPU Manager 等旧失败需要逐项定向重跑。

S5.3c 需要汇总所有 shard、保证支持面失败为 0、逐条解释排除项，恢复临时 e2e 配置并证明双
Worker exact-zero。S6.1～S6.4 与最终一秒门禁 S5.4d 均未开始；普通启动当前约 1.94 秒 P95，
一秒目标仍需后续 template/restore 快路径。

## 验证

- 代码：Host cgroup 78/78、完整 Shim lib 288/288、worker process 1/1、fmt/diff check 通过。
- build/deploy：`inv-9896bxggdx`、`inv-0896gx0uqt`。
- 热路径 trace：`inv-b896kd0dc3`，`SYSTEMCTL_TOTAL=0`、`SYSTEMCTL_SHOW_TOTAL=0`。
- 串行/并发：`inv-8896px02qi`、`inv-a896ubgp5c`。
- 故障与清理：containerd/RuntimeResource restart `inv-8896vq0h35`/`inv-b896vt0di3`；
  worker kill `inv-0896we0txv`；Shim kill `inv-v896wugbga`；cancel `inv-6896x80ii2`；最终
  exact-zero `inv-0896xd0qnv`。
- 当前集群 control 不注册为 Node，W1/W2 均 Ready；W1 的 `kubelet-e2e.service` active、
  `kubelet.service` inactive，W2 使用普通 kubelet。W1 当前 Cube Shim/worker 为 0；CRI 列表中的
  10 Pod/17 container 是 runc 系统负载，不是 Cube 残留。

## 阻塞

无外部阻塞。`K8S-OQ-033` 是当前第一个产品缺口，不需要用户决策；先用官方 Hostname、
KubeletManagedEtcHosts 定向 shard 复现并实现。tmpfs identity、hostNetwork/hostPID/hostIPC 等按
既有支持范围分类，无法支持的测试必须保留上游名称、技术原因和问题 ID，不能从报告静默删除。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本
PoC 创建的资源；名称带“勿删”的 CVM/TKE 不得删除。不得覆盖已有证据、构建产物、Guest assets
和回滚副本；handoff 不记录凭证、token 或 kubeconfig 内容。

## 下一步

1. W1 exact-zero 后部署 `fa278467` 三个 runtime 二进制，保留 W1 Agent/kernel，校验版本与
   RuntimeClass admission 环境。
2. 先跑 Hostname/`/etc/hosts`、SIGKILL/sysctl、CPU Manager/PodResources、restartable sidecar
   等旧失败定向 shard；真实缺陷立即修复并复跑，环境问题修 runner。
3. 按固定、互斥 focus/skip 表执行剩余 NodeConformance shard，每 shard 单独 timeout、JSON、
   JUnit、日志、资源清理和 exact-zero；不得再使用单个 6 小时 suite 作为唯一验收。
4. 汇总 477 项的执行覆盖和支持面结论，完成 S5.3c；恢复普通 kubelet/containerd 临时片段、
   admission policy 与 auth carrier，双 Worker exact-zero 后交同一 reviewer 终验。
