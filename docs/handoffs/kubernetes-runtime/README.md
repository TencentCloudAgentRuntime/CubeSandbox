# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S6.1 `NOT_STARTED`。S5.3、S5.3a、S5.3b、S5.3c 与 S5.4a～S5.4c 均为 `DONE`。
下一步冻结 RuntimeTemplate、PodSnapshot、Pause/Resume 的产品与技术契约；不回退已验收的
普通 worker 启动路径。

## 基线

最后验证实现 commit 为 `643812879228e513a20e3a29499af7b9cfe57480`，tree 为
`41297a0a1ed1eb88ff39ab0e34245278fad67ecc`；S5.3 收口证据 commit 为 `3a0b7873`。
W1/W2 已部署最终 Host CubeShim/worker/runtime（SHA-256 前缀 `410d1799`、`3ff0b7d9`、
`ea6df43e`）和 Agent ext4 `3c36bcb9…`。`RuntimeClass/cube` 保留。

## 已完成

Kubernetes v1.36.4 官方 477 个 `[NodeConformance]` `It` 已完整执行和唯一归并：456
Passed、17 Failed、4 Skipped；Cube 可归因通过 453 项。17 个失败包括 16 个有明确后续
方案的架构差异和 1 个既有 kubeadm control-plane 测试环境限制；没有将其声明为全绿或
认证。最终 Device/PodResources 为 10/10 Passed、1 个无 SR-IOV VF 的条件 Skip。支持路径
发现的 Device、CPU/NUMA、route、stats、hostname、sysctl、SIGKILL 与 sidecar 等缺陷已修复。
同一 reviewer 终审 `PASS`（P0/P1/P2=0）。完整证据见
[S5.3 最终报告](./evidence/s5.3/s5.3b-nodeconformance.md)。

S5.4b/c 已完成每 Pod `cube-vmm-worker` 拆分及普通启动快路径：正常启动不再执行
`systemctl show`；50 次串行与 5×10 并发成功率 100%、PullImage=0。串行
PodScheduled→Ready P95=1935.438ms、RunPodSandbox P95=1575.632ms。

## 未完成

- S6.1～S6.4：模板、快照与暂停恢复设计和实现。
- S4.1～S4.3：状态重连、Reconcile 与可观测性，权威计划中仍为 `NOT_STARTED`。
- S5.4d：通过 RuntimeTemplate 把预拉取镜像的 PodScheduled→Ready P95 收到 1 秒内，
  并对成为默认路径的改动重跑 Node E2E。
- S5.1/S5.2：安装共存、升级和回滚产品化；完整多节点 soak/PVC 验收也尚未完成。
- S5.3 已解释差异保留在 `K8S-OQ-025/034/035/036/037/038`，由 S6.1 决定实现或专用
  fixture/hardware 的闭环方式。

## 验证

- 477 项归并输出 SHA-256：`fe78040305a0f7bc58d8a2bc569d5a755c5a02d7bca8a0fa1466d0cbc0fd2424`。
- Device/PodResources：`inv-389w3ggrk9`；privileged 定向终审：`inv-689xwbgpag`。
- 双 Worker exact-zero：`inv-98a04qgm41`。
- W1/W2 Ready、kube-system 非 Ready=0、e2e namespace/policy=0：`inv-a8a04sguer`。
- `git diff --check`、credential scan、`make handoff-validate` 与 reviewer 终审均通过。

## 阻塞

无外部阻塞。S6.1 需要与用户确认 PodSnapshot 是否保存进程状态、writable layer/emptyDir、
PVC/CSI 一致性、节点本地与 COS 分发、保留策略，以及 Pause/Resume 是否纳入当前 PoC。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。只操作本
PoC 创建的云资源；所有带“勿删”的 CVM/TKE/COS 资源不得删除。不得覆盖既有证据、Guest
assets 和回滚副本；不得在仓库或 handoff 中记录凭证、token、私钥或 kubeconfig 内容。

## 下一步

1. 先复现归并脚本的 477/456/17/4 与最终恢复证据，不重跑已关闭的全套测试。
2. 完成 S6.1 决策表：三类状态模型、snapshot 切点、worker IPC、设备重绑定、artifact
   manifest、CRD/annotation、卷/Secret、兼容性和分发语义。
3. reviewer 通过且用户确认 S6.1 后，先实现 RuntimeTemplate（S6.2），再做显式
   PodSnapshot（S6.3）；Pause/Resume 按 S6.1 决策处理，最后执行 S5.4d 一秒与 E2E 回归。
