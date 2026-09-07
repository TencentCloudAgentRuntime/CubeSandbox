# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S5.5b `IN_PROGRESS`。S5.3、S5.3a、S5.3b、S5.3c、S5.4a～S5.4c 与 S5.5a 均为 `DONE`。
用户决定先优化普通 OCI 冷启动，目标是串行 PodScheduled→Ready P95≤1.5s 并消除并发放大；
S5.5 完成后再进入 S6.1。不得回退已验收的普通 worker 启动路径。

## 基线

最后验证实现 commit 为 `79f6bcb444447e8442f1893a1963206d3b7024a6`，tree 为
`3f9ae5ccd1e24eb5dc41fd52286acf8dcc267789`。W2 已恢复最终 Host CubeShim/worker/runtime：
Shim SHA-256 `4bcc5d53…`、worker `5b0b0d9f…`、RuntimeResource harness `08c9a8f0…`；
Agent ext4 为 `3c36bcb9…`。`RuntimeClass/cube` 保留。W1 由 GLM 独立使用，主线未触碰。

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

S5.5a 已完成最终制品基线：worker 串行/5×10 Ready P95 为 1965.379/2899.045ms，trace
覆盖最低 99.77% 且开销低于 0.05%；worker/embedded 的 1/5/20 Pod×3 轮资源矩阵完成，
20 Pod 稳态 cgroup 为 104.664/99.989MiB/Pod。virtiofs 0/1/2 配对估计、生产制品恢复与
exact-zero 均通过；同一 reviewer 终审 `PASS`（P0/P1/P2=0）。详见
[S5.5a 最终基线](./evidence/s5.5/s5.5a-final-baseline.md)。

## 未完成

- S5.5b～S5.5f：普通冷启动性能优化；退出门禁为串行 P95≤1.5s、5×10 并发 P95≤1.8s，
  冲刺并发 P95≤1.5s。
- S6.1、S6.2a～c、S6.3～S6.4：模板、快照与暂停恢复设计和实现；S6.2c 负责模板路径密度和
  RuntimeClass overhead 最终标定。
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
- S5.5a W2/控制/本地工具权威证据包 SHA-256 分别为 `38841b44…`、`00cf570e…`、
  `8bcd0b24…`；全部从 COS 反向下载校验，local-tooling-v2 内嵌 37 项 checksum 全部通过。
- S5.5a 生产恢复 `inv-a8cm3egxjv`；W2 exact-zero `inv-08cm4gg07f`；控制端目标 W2
  Ready 且测试对象归零 `inv-a8cm6pgic4`；reviewer `PASS`（P0/P1/P2=0）。
- `git diff --check`、credential scan、`make handoff-validate` 与 reviewer 终审均通过。

## 阻塞

无外部阻塞。GLM 的冻结分支全量 Node E2E 是独立并行验证，不占用主线 Stage，也不阻塞
S5.5；只有绑定 commit/artifact SHA 且原始结果可复验后才接收入回归证据。GLM 当前使用的
W1 可处于 NotReady；S5.5 只门禁 W2 `vm-200-13-ubuntu`，不得为主线恢复或修改 W1。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。只操作本
PoC 创建的云资源；所有带“勿删”的 CVM/TKE/COS 资源不得删除。不得覆盖既有证据、Guest
assets 和回滚副本；不得在仓库或 handoff 中记录凭证、token、私钥或 kubeconfig 内容。

## 下一步

1. 执行 S5.5b：只保留同 sandbox 线性化，把 adapter、Coordinator 和 Store 改为
   per-sandbox/分片并发，先将 adapter 跨 sandbox lock-wait P95 收到 10ms 内。
2. 按 S5.5c～S5.5e 依次关闭外部网络命令、重复持久化/placement 等待和 Guest
   cold boot；每个子阶段只在专项、故障与 exact-zero 通过后进入下一阶段。
3. S5.5f 达到串行 P95≤1.5s、并发 P95≤1.8s，并完成受影响 Node E2E 回归；完整方案见
   [S5.5 性能优化方案](../../zh/dev/kubernetes-runtime-performance-s5.5.md)。
4. S5.5 后进入 S6.1；按 S6.2a 恢复链路、S6.2b 动态身份、S6.2c 性能/密度/overhead 顺序
   完成 RuntimeTemplate 和 S5.4d 一秒门禁，再进入 S6.3 PodSnapshot。
