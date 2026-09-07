# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S5.5a `NOT_STARTED`。S5.3、S5.3a、S5.3b、S5.3c 与 S5.4a～S5.4c 均为 `DONE`。
用户决定先优化普通 OCI 冷启动，目标是串行 PodScheduled→Ready P95≤1.5s 并消除并发放大；
S5.5 完成后再进入 S6.1。不得回退已验收的普通 worker 启动路径。

## 基线

最后验证实现 commit 为 `643812879228e513a20e3a29499af7b9cfe57480`，tree 为
`41297a0a1ed1eb88ff39ab0e34245278fad67ecc`；S5.3 收口与分类证据最新 commit 为
`c6921b17`（最终结果基线 `3a0b7873`）。
W1/W2 已部署最终 Host CubeShim/worker/runtime（SHA-256 前缀 `410d1799`、`3ff0b7d9`、
`ea6df43e`）和 Agent ext4 `3c36bcb9…`。`RuntimeClass/cube` 保留。

## 已完成

Kubernetes v1.36.4 官方 477 个 `[NodeConformance]` `It` 已完整执行和唯一归并：456
Passed、17 Failed、4 Skipped；Cube 可归因通过 453 项。17 个失败包括 16 个有明确后续
方案的架构差异和 1 个既有 kubeadm control-plane 测试环境限制；没有将其声明为全绿或
认证。最终 Device/PodResources 为 10/10 Passed、1 个无 SR-IOV VF 的条件 Skip。支持路径
发现的 Device、CPU/NUMA、route、stats、hostname、sysctl、SIGKILL 与 sidecar 等缺陷已修复。
同一 reviewer 终审 `PASS`（P0/P1/P2=0）。完整证据见
[S5.3 最终报告](./evidence/s5.3/s5.3b-nodeconformance.md)和
[477 项分类与失败分析](./evidence/s5.3/s5.3-nodeconformance-classification.md)。

S5.4b/c 已完成每 Pod `cube-vmm-worker` 拆分及普通启动快路径：正常启动不再执行
`systemctl show`；50 次串行与 5×10 并发成功率 100%、PullImage=0。串行
PodScheduled→Ready P95=1935.438ms、RunPodSandbox P95=1575.632ms。

S5.5 性能方案已冻结：依次执行逐 Pod tracing、RuntimeResource 跨 Pod 解锁、进程内 netlink、
持久化/cgroup 快路径、Guest cold boot 和端到端回归。并发新增 RunPodSandbox 平均 783ms 中
85.4% 位于 VMM 前；串行 RunPodSandbox 约 72% 位于 Guest 启动到 vsock。

## 未完成

- S5.5a～S5.5f：普通冷启动性能优化；退出门禁为串行 P95≤1.5s、5×10 并发 P95≤1.8s，
  冲刺并发 P95≤1.5s。
- S6.1～S6.4：模板、快照与暂停恢复设计和实现。
- S4.1～S4.3：状态重连、Reconcile 与可观测性，权威计划中仍为 `NOT_STARTED`。
- S5.4d：通过 RuntimeTemplate 把预拉取镜像的 PodScheduled→Ready P95 收到 1 秒内，
  并对成为默认路径的改动重跑 Node E2E。
- S5.1/S5.2：安装共存、升级和回滚产品化；完整多节点 soak/PVC 验收也尚未完成。
- S5.3 已解释差异保留在 `K8S-OQ-025/034/035/036/037/038`，由 S6.1 决定实现或专用
  fixture/hardware 的闭环方式。

## 验证

- 477 项归并输出 SHA-256：`fe78040305a0f7bc58d8a2bc569d5a755c5a02d7bca8a0fa1466d0cbc0fd2424`。
- 477 项已归入 8 个能力域、63 个上游测试文件；分类与失败分析经同一 reviewer
  `PASS`（P0/P1/P2=0）。
- Device/PodResources：`inv-389w3ggrk9`；privileged 定向终审：`inv-689xwbgpag`。
- 双 Worker exact-zero：`inv-98a04qgm41`。
- W1/W2 Ready、kube-system 非 Ready=0、e2e namespace/policy=0：`inv-a8a04sguer`。
- `git diff --check`、credential scan、`make handoff-validate` 与 reviewer 终审均通过。

## 阻塞

无外部阻塞。S5.5a 需要在 W2 用最终 Host/Guest 制品重跑基线，因为既有性能数字来自
`fa278467`，而最终代码已把无显式资源 Pod 的默认 VM 内存从 256MiB 调整为 512MiB。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。只操作本
PoC 创建的云资源；所有带“勿删”的 CVM/TKE/COS 资源不得删除。不得覆盖既有证据、Guest
assets 和回滚副本；不得在仓库或 handoff 中记录凭证、token、私钥或 kubeconfig 内容。

## 下一步

1. 执行 S5.5a：部署最终制品，加入统一 monotonic tracing，重跑 50 串行和 5×10 并发基线。
2. 按 S5.5b～S5.5e 依次关闭跨 Pod 大锁、外部网络命令、重复持久化/placement 等待和 Guest
   cold boot；每个子阶段只在专项、故障与 exact-zero 通过后进入下一阶段。
3. S5.5f 达到串行 P95≤1.5s、并发 P95≤1.8s，并完成受影响 Node E2E 回归；完整方案见
   [S5.5 性能优化方案](../../zh/dev/kubernetes-runtime-performance-s5.5.md)。
4. S5.5 后进入 S6.1，最终由 RuntimeTemplate 和 S5.4d 关闭一秒目标。
