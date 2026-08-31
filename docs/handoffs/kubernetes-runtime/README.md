# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S2.3 `IN_PROGRESS`：S2.2 Init 与定向重启已完成并获同一 reviewer `APPROVE`；当前开始验证 Pod namespace 共享、PID 默认隔离与 `shareProcessNamespace`。

## 基线

最后一项已验证实现 commit 为 `9467e4a07d394b208a2acc2377e90133a0e763fc`，完整 tree 为 `187fd167dacc7938886e61025c1dcad733e02d3e`。S2.2 最终 shim SHA-256 为 `39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd`。

## 已完成

S0、S1.1～S1.4 和 S2.1～S2.2 均为 `DONE`。S2.2 已证明双 init 严格串行、失败 init 定向重试、普通容器定向重建和 survivor 不受影响；三例均清理旧 Task/rootfs 并恢复全量基线。同一 reviewer 最终 `APPROVE`。

## 未完成

S2.3 尚未验证 net/IPC/UTS 在 Pod 内共享、PID 默认隔离和 `shareProcessNamespace: true`；hostNetwork/hostPID/hostIPC 应明确拒绝。可写 `emptyDir` 问题仍归 S3.1。

## 验证

S2.2 诊断 `inv-983ggb0u6k` 与 reviewer 加固终验 `inv-a83gx50k5f` 均为 `SUCCESS`。终验脚本 SHA-256 为 `b896af6b8aaf2c65eb88f28db227966071feb1d24d168ef18fa0de0ff2327e05`；三例 active lease 均归零、tombstone 增量为 3，同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s2.2/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-010` 目标 S5；`K8S-OQ-011` 目标 S3.1，均不阻塞 S2.3。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

先复现 `evidence/s2.2/README.md` 的 `inv-a83gx50k5f` 摘要。随后为 S2.3 建立默认 namespace、`shareProcessNamespace: true` 和 host namespace 拒绝矩阵；记录每容器 `/proc`、hostname、IPC 对象、网络接口/Pod IP、Sandbox/VM/shim 与删除基线。完成后交同一 reviewer。
