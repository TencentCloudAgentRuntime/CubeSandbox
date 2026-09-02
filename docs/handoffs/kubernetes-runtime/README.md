# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.4 `VALIDATING`。实现和云端验收候选已完成，等待同一 reviewer 明确返回
`APPROVE S3.4c DONE`；未获批准前不得进入 S3.4d。

## 基线

最后一项已验证实现 commit 为 `2a23aa3cccddcf9c5c0f9e4a4986251ef92dbae2`；上一个已完成
Stage 的证据 commit 为 `7b9d2afe`。S0 双 Worker 当前 CubeShim/Agent ext4/`cube-runtime`
SHA-256 为 `f6747958…`/`b7cd4c4b…`/`8c17375d…`；运行时根为
`/opt/cubesandbox-s0-multinode-runtime-2269a3b3`。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b、S3.4c.1～S3.4c.3 均为
`DONE`。S3.4c.4 候选已完成：Shim 160/160、OOM notifier 4/4；六 Pod/九容器
Guest/Host 逐对象证据；Host CPU/memory/PIDs；Guest 正常期和启动阶段 OOM；survivor；
containerd restart；inactive scope Kubernetes 删除；双 Worker exact zero。

## 未完成

S3.4c.4 reviewer 门禁和 S3.4d。`K8S-OQ-017`、`021`、`022` 在 S3.4d 验证；
`K8S-OQ-018`～`019` 保持后续范围。容量内 resize 基础路径已通过，但最终组合中的
“长 exec + resize”超时未记成通过。

## 验证

原始 Guest/Host 证据为 `inv-686i7a0qux`、`inv-686i7a0quv`、`inv-386i7ags0q`，文件
与 SHA-256 见 [S3.4c.4 摘要](./evidence/s3.4/s3.4c.4-execution-summary.md)。
`inv-886i0qgtq9` 启动即 OOM 8/8 为 `OOMKilled/137`；
`inv-v86i55g64g`/`inv-b86i5egc5x` 完成 inactive scope 删除；
`inv-a86ig40cbx`/`inv-086ig5gp25` 双 Worker 精确归零；`inv-886iicgsqw` 证明
nodes 3/3 Ready、无临时 namespace/Failed Pod、apiserver ready；
`inv-886iicgsqu`/`inv-986iicgw96` 完成最终制品审计。

## 阻塞

无外部阻塞或待用户决策。默认小 VM 高并发启动出现 `ReleasePending`，证据不足以归因 Host
OOM，记录为 `K8S-OQ-021`；containerd restart 后长 CPU exec 与 resize 并发发生 ttrpc/passfd
超时，记录为 `K8S-OQ-022`。两轮异常均已清理至 exact zero。inactive scope 语义已由
`2a23aa3c` 和定向云端回归关闭为 `K8S-OQ-020=DECIDED`。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。
云端仅操作本 PoC 创建的资源；名称带“勿删”的 CVM/TKE 不得删除。现有证据、构建产物和
回滚副本不得覆盖，handoff 不记录凭证。

## 下一步

1. reviewer 独立复核 `2a23aa3c`、三份 raw 证据、OOM/scope 竞态和失败边界。
2. 仅在取得 `APPROVE S3.4c DONE` 后更新 S3.4c 状态并启动 S3.4d。
3. S3.4d 优先复现 `K8S-OQ-021/022`，完成双层资源、swap/hugepage/PIDs 和
   ephemeral-storage 支持矩阵。
4. S3.4 关闭后立即运行固定 Kubernetes v1.36.4 E2E/Conformance runner。
