# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.3 `IN_PROGRESS`：实现 RuntimeClass overhead 输入、Host 静态 leaf CPU/memory/PIDs ceiling、controller WAL 与恢复决策；并提前运行 Kubernetes Node E2E/Conformance 诊断基线。

## 基线

最后一项已验证实现 commit 为 `90edf7bf1bec222c7b4e3fc353478eabe6a42db5`，tree 为 `8c2301d0034a19a42fda73e170340a2cafe3a8f9`；上一个验收证据 commit 为 `13625f99`。S0 双工作节点当前 CubeShim/Agent/`cube-runtime` SHA-256 为 `7ba54f3d…`/`870fd590…`/`8c17375d…`；固定构建 Host lifecycle 55/55、双节点 systemd gate 200、RuntimeClass、live Delete、PID 诱饵、containerd restart 和 legacy/watchdog restart 均通过。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b 与 S3.4c.1～S3.4c.2 全部 `DONE`。S3.4c.2 最终实现 `90edf7bf` 完成 Host placement、takeover/scanner、process fencing 和 exact cleanup；固定测试、完整云端故障矩阵及同一 reviewer 批准均完成。

## 未完成

S3.4c.3～S3.4d 尚未完成。S3.4c.3 的 controller WAL/RuntimeClass overhead 已开始，S3.4c.4 压力矩阵尚未开始。极端 unchecked `memory.max` 下调按 `K8S-OQ-017` 跟踪，inactive systemd scope 的 Release 幂等语义按 `K8S-OQ-020` 跟踪。

## 验证

`90edf7bf` 在 `2a3927a1` 的 PVM stale PID 兼容之上，关闭 scanner/operation lock 死锁窗口、Host placement record 长持锁和 cleanup signal 顺序问题。`inv-086cqv0bdf` 固定构建 55/55；`inv-v86cvcgkke`/`inv-086cvbg072` 双节点部署并各通过 systemd gate 200。新基线 live Delete `inv-986cwegjsh`、sibling/PID 诱饵 `inv-386d0802k1`、containerd restart `inv-686d0r0frx`/`inv-a86d18gp2k`、legacy/watchdog restart `inv-p86d0q07k9` 与最终双 Worker 零基线 `inv-b86d1xgwuh`/`inv-v86d20090k` 全通过。原 S0 8 Pod 跨节点回归证据保持，但工作负载已按用户授权删除；详见 [S3.4c.2 终验](./evidence/s3.4/s3.4c.2-execution-summary.md)。

## 阻塞

无外部阻塞，也无待用户决策。S0 跨节点 Cube 验证环境继续保留，已验收的 8 Pod 已按用户授权删除且两个 Worker 回到精确零基线。一次 inactive systemd scope Release 的可重试错误作为非阻断 `K8S-OQ-020` 进入 S3.4c.4/E2E；`K8S-OQ-014`～`K8S-OQ-016` 等待 S3.4c.3～c.4 最终关闭，`K8S-OQ-017`～`019` 继续跟踪极端内存下调、VM hotplug 与有限 Pod PID 语义。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 CVM/自建 Kubernetes、额外 TKE `cls-1oqe2py4` 及其节点 `ins-h06xpkbw`、`ins-lus07026`，以及私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖，名称带“勿删”的资源不得删除。

## 下一步

先在不改变当前双 Worker 零基线的前提下，固定 Kubernetes v1.36.4 Node E2E/Conformance runner、运行方式与测试清单；随后实现 S3.4c.3 的 CRI overhead decoder、预算向量和 controller WAL，按纯函数→云端特权 controller→真实 RuntimeClass/resize 顺序验收。同一 reviewer 明确批准 S3.4c.3 后才进入 S3.4c.4。
