# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.4 `VALIDATING`：云端 Host/Guest 压力、QoS/多容器兼容、故障恢复、survivor 隔离与 exact-baseline 审计已通过，等待同一 reviewer 返回 `APPROVE S3.4c DONE`。

## 基线

最后一项已验证实现 commit 为 `90026f590eda8a73f1c3f9021024e3ee3f4896b7`；上一个已完成 Stage 的验收证据 commit 为 `7b9d2afe`。S0 双工作节点当前 CubeShim/Agent/`cube-runtime` SHA-256 为 `a5c68da0…`/`9206e77b…`/`8c17375d…`，`inv-b86h6n067j`/`inv-386h6n05t5` 的完整 manifest 校验通过；Kubernetes v1.36.4 六 Pod 压力矩阵、Guest `OOMKilled/137`、在线 containerd restart、双节点 exact zero 和最终集群健康均通过。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b 与 S3.4c.1～S3.4c.3 全部 `DONE`。S3.4c.4 候选已完成 QoS/多容器三层数值、Host CPU/memory/PIDs、Guest 定向 OOM、survivor、容量内 resize、containerd restart 和 exact-baseline 矩阵。

## 未完成

S3.4c.4 等待 reviewer，S3.4d 尚未开始。极端 unchecked `memory.max` 下调按 `K8S-OQ-017` 跟踪，inactive systemd scope 的 Release 幂等语义按 `K8S-OQ-020` 带入 Kubernetes E2E 删除回归。

## 验证

`90026f59` 修复 Agent cgroup v2 OOM/exit 事件竞态；固定 builder `inv-386gur0e65` 专项 2/2 并产出 Agent `9206e77b…`。`inv-a86gc90t3r`、`inv-b86gd40042`、`inv-b86gfd0fqf` 完成六 Pod Guest/parent/leaf 矩阵；CPU/PIDs/Host OOM/resize 与在线 containerd restart 全部通过。最终 `inv-386h170wa5` 为 `OOMKilled/137` 且三类 survivor 稳定，`inv-086h2egmq0`/`inv-086h2f0c1g` 双 Worker 精确归零，`inv-386h37gkc2` 集群健康。详见 [S3.4c.4 候选摘要](./evidence/s3.4/s3.4c.4-execution-summary.md)。

## 阻塞

无外部阻塞，也无待用户决策。S0 集群保持 3/3 Ready 且两个 Worker 为精确零基线。`K8S-OQ-014` 已由三层压力证据关闭；`K8S-OQ-015`～`017` 在 S3.4d 继续组合/边界验证，`K8S-OQ-018`～`019` 保持后续范围。历史 inactive scope Release 偶发项本轮未复现，以非阻断 `K8S-OQ-020` 进入 Kubernetes E2E。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 CVM/自建 Kubernetes、额外 TKE `cls-1oqe2py4` 及其节点 `ins-h06xpkbw`、`ins-lus07026`，以及私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖，名称带“勿删”的资源不得删除。

## 下一步

复核 `90026f59` 候选证据并取得同一 reviewer 的 `APPROVE S3.4c DONE`。批准后更新 S3.4c.4/S3.4c 为 `DONE`，启动 S3.4d 双层资源与非 cgroup 支持矩阵；S3.4 关闭后立即运行固定 Kubernetes v1.36.4 E2E/Conformance runner。
