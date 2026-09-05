# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S5.3d `IN_PROGRESS`。S5.3a～S5.3c 与 S5.4a～S5.4c 均为 `DONE`；用户决定先完成
Kubernetes v1.36.4 全量 Node E2E 和逐用例运行时归因，再进入 S6.1。OpenCode 只在独立
clone 中诊断，最终结果由独立 runner 生成，不回退已验收的普通 worker 启动路径。

## 基线

最后验证实现 commit 为 `643812879228e513a20e3a29499af7b9cfe57480`，tree 为
`41297a0a1ed1eb88ff39ab0e34245278fad67ecc`；S5.3 收口与分类证据最新 commit 为
`c6921b17`（最终结果基线 `3a0b7873`）。
W1/W2 已部署最终 Host CubeShim/worker/runtime（SHA-256 前缀 `410d1799`、`3ff0b7d9`、
`ea6df43e`）和 Agent ext4 `3c36bcb9…`。`RuntimeClass/cube` 保留。

S5.3d 冻结 source commit 为 `9ac62220ead8a392280aeb9ac616981fde8ab484`、tree 为
`f88919f36d26158b5e3118ffea9bead87fe1e3be`；本地冻结分支
`freeze/node-e2e-v1.36.4-20260906`、annotated tag
`node-e2e-baseline-v1.36.4-20260906`。OpenCode 独立 clone 位于
`/root/code/CubeSandbox-opencode-node-e2e-20260906`，无 object alternates 和可写 origin。

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

## 未完成

- S5.3d：生成全部 Node E2E 权威 inventory 与 profile/shard manifest，补齐 Pod/CRI/
  containerd/Cube 运行时归因，由 OpenCode 诊断并在独立验收节点完成最终执行、聚合和复验。
- S6.1～S6.4：模板、快照与暂停恢复设计和实现。
- S4.1～S4.3：状态重连、Reconcile 与可观测性，权威计划中仍为 `NOT_STARTED`。
- S5.4d：通过 RuntimeTemplate 把预拉取镜像的 PodScheduled→Ready P95 收到 1 秒内，
  并对成为默认路径的改动重跑 Node E2E。
- S5.1/S5.2：安装共存、升级和回滚产品化；完整多节点 soak/PVC 验收也尚未完成。
- S5.3 已解释差异保留在 `K8S-OQ-025/034/035/036/037/038`，由 S6.1 决定实现或专用
  fixture/hardware 的闭环方式。

## 验证

- S5.3d 冻结 branch/tag 均解析到 commit `9ac62220`；tag object `8170c1f5…`；独立 clone
  HEAD/tree 与冻结值一致、工作区 clean、独立 `.git`、无 object alternates 和 remote。
- 验收计划与防作弊门禁见
  [S5.3d OpenCode 计划](./evidence/s5.3/s5.3d-full-node-e2e-opencode-plan.md)。
- 477 项归并输出 SHA-256：`fe78040305a0f7bc58d8a2bc569d5a755c5a02d7bca8a0fa1466d0cbc0fd2424`。
- 477 项已归入 8 个能力域、63 个上游测试文件；分类与失败分析经同一 reviewer
  `PASS`（P0/P1/P2=0）。
- Device/PodResources：`inv-389w3ggrk9`；privileged 定向终审：`inv-689xwbgpag`。
- 双 Worker exact-zero：`inv-98a04qgm41`。
- W1/W2 Ready、kube-system 非 Ready=0、e2e namespace/policy=0：`inv-a8a04sguer`。
- `git diff --check`、credential scan、`make handoff-validate` 与 reviewer 终审均通过。

## 阻塞

无外部阻塞。冻结引用目前只在本地；向 `payall4u` 发布因没有本轮明确的外发授权而未执行，
不影响本机独立 clone。S6.1 的快照决策继续延期到 S5.3d 完成后。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。只操作本
PoC 创建的云资源；所有带“勿删”的 CVM/TKE/COS 资源不得删除。不得覆盖既有证据、Guest
assets 和回滚副本；不得在仓库或 handoff 中记录凭证、token、私钥或 kubeconfig 内容。
OpenCode 不得使用 `/root/code/CubeSandbox`，也不得移动 S5.3d 冻结 branch/tag。

## 下一步

1. 独立 runner 用固定 `e2e_node.test` 生成完整 inventory、profile/shard manifest 和预运行
   哈希；为 Pod UID 到 Cube worker 建立归因采集链。
2. 只在独立 clone 和专用诊断节点启动 OpenCode；候选修复返回 commit 与最小复现，由 Codex
   review。任何代码/制品变化都创建新冻结版本，旧 Passed 不跨基线合并。
3. 在独立验收节点执行同一最终基线；全部 spec 唯一闭环、归因 `UNKNOWN=0`、原始证据哈希、
   随机 10% Passed 复验及 exact-zero 通过后，才能关闭 S5.3d 并进入 S6.1。
