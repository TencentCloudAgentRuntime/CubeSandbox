# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S2.2 `IN_PROGRESS`：S2.1 动态多容器已完成并获同一 reviewer `APPROVE`；当前开始验证 init container 顺序、失败重试和普通容器 restartPolicy 语义。

## 基线

最后一项已验证实现 commit 为 `ce3afe4c494b23a8b32a06c0221554629090d926`，完整 tree 为 `abce5a92f26bdb1626cb532aafddf1ceb2681e9b`。S2.1 最终 shim SHA-256 为 `39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd`。

## 已完成

S0、S1.1～S1.4 和 S2.1 均为 `DONE`。S2.1 的两个 Task 共享一个 Sandbox/VM/Pod IP；删除 alpha 后旧 Task 消失、beta 与 shim PID 不变，kubelet 只重建 alpha 并恢复 Pod Ready；整 Pod 删除恢复全量基线。同一 reviewer 最终 `APPROVE`。

## 未完成

S2.2 尚未验证 init container 严格顺序、失败重试、完成后 Task 清理，以及普通容器按 restartPolicy 定向重启且不重启 VM、不影响其他容器。TTY/stdin 不纳入 S2.2。

## 验证

S2.1 严格构建 `inv-083fdrgb3k` 与完整加固终验 `inv-083g3u0npg` 均为 `SUCCESS`。终验脚本 SHA-256 为 `55a5323ad1eea4a17680bd99f921a2f99a5834b13543a5b65d8b9a3e56e8627d`，shim 为 `39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd`；同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s2.1/README.md`。

## 阻塞

无外部阻塞。durable tombstone 的生产保留/压缩记录为 `K8S-OQ-010`，目标 S5，不阻塞 S2.2。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

先复现 `evidence/s2.1/README.md` 的 `inv-083g3u0npg` 终验摘要。随后为 S2.2 建立最小 init-success、init-failure-retry 和双普通容器 crash/restart 基线；记录 Task/container ID、顺序、restart count、Sandbox/Pod UID/IP、shim PID 和 VM 路径，确认单容器重启不影响 survivor，整 Pod 删除恢复 S2.1 全量基线。完成后交同一 reviewer。
