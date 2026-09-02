# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.3 `IN_PROGRESS`：实现 RuntimeClass overhead 输入、Host 静态 leaf CPU/memory/PIDs ceiling、controller WAL 与恢复决策；并提前运行 Kubernetes Node E2E/Conformance 诊断基线。

## 基线

最后一项已验证实现 commit 为 `6c7eb7540b0da846a1774c95a4b81ad4deccf15c`；上一个已完成 Stage 的验收证据 commit 为 `fe7b4044`。S0 双工作节点当前 CubeShim/Agent/`cube-runtime` SHA-256 为 `c17d0164…`/`870fd590…`/`8c17375d…`；固定 builder 153/153、双节点 systemd gate 200、RuntimeClass、真实 V1、controller after-write crash recovery 与最终 exact zero 均通过。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b 与 S3.4c.1～S3.4c.2 全部 `DONE`。S3.4c.2 最终实现 `90edf7bf` 完成 Host placement、takeover/scanner、process fencing 和 exact cleanup；固定测试、完整云端故障矩阵及同一 reviewer 批准均完成。

## 未完成

S3.4c.3～S3.4d 尚未完成。S3.4c.3 实现与云证据已闭合，当前只等待同一 reviewer 最终批准；S3.4c.4 压力矩阵尚未开始。极端 unchecked `memory.max` 下调按 `K8S-OQ-017` 跟踪，inactive systemd scope 的 Release 幂等语义按 `K8S-OQ-020` 跟踪。

## 验证

`6c7eb754` 完成 checked overhead、静态 leaf ceiling、controller forward/rollback WAL、epoch fencing 和 crash matrix。`inv-386f3ggcjd` 固定构建 153/153；`inv-v86f7i0r8v`/`inv-b86f7j09wh` 双节点部署并各通过 gate 200；最终 V1 `inv-386f8tg1kc`/`inv-a86f940j5r` 和真实 after-write crash `inv-986fbag33m`/`inv-686fct0t83` 通过，最终双 Worker `inv-886f9m06ba`/`inv-b86fdng3d5` 精确归零。详见 [S3.4c.3 执行摘要](./evidence/s3.4/s3.4c.3-execution-summary.md)。

## 阻塞

无外部阻塞，也无待用户决策。S0 跨节点 Cube 验证环境继续保留，已验收的 8 Pod 已按用户授权删除且两个 Worker 回到精确零基线。一次 inactive systemd scope Release 的可重试错误作为非阻断 `K8S-OQ-020` 进入 S3.4c.4/E2E；`K8S-OQ-014`～`K8S-OQ-016` 等待 S3.4c.3～c.4 最终关闭，`K8S-OQ-017`～`019` 继续跟踪极端内存下调、VM hotplug 与有限 Pod PID 语义。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 CVM/自建 Kubernetes、额外 TKE `cls-1oqe2py4` 及其节点 `ins-h06xpkbw`、`ins-lus07026`，以及私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖，名称带“勿删”的资源不得删除。

## 下一步

请同一 reviewer 按恢复决策表映射与云证据最终复核 S3.4c.3；明确批准后更新 Stage 为 `DONE`，随即进入 S3.4c.4 压力/兼容矩阵并固定 Kubernetes v1.36.4 E2E/Conformance runner。
