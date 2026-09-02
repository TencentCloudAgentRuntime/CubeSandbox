# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4d `IN_PROGRESS`：组合验证 Host/Guest 双层资源、更新故障和非 cgroup 资源，冻结首版
支持矩阵。S3.4c 已由同一 reviewer 明确 `APPROVE S3.4c DONE`。

## 基线

最后一项已验证实现 commit 为 `2a23aa3cccddcf9c5c0f9e4a4986251ef92dbae2`；S3.4c 最终
证据 commit 为 `24d2d188`。S0 双 Worker 当前 CubeShim/Agent ext4/`cube-runtime`
SHA-256 为 `f6747958…`/`b7cd4c4b…`/`8c17375d…`；运行时根为
`/opt/cubesandbox-s0-multinode-runtime-2269a3b3`。

## 已完成

S0、S1、S2、S3.1～S3.3、S3.4a～S3.4c 均为 `DONE`。S3.4c reviewer 独立复核
OOM armed barrier、inactive scope cleanup、六 Pod/九容器 raw 证据、问题边界、本地检查和
云端 clean baseline，确认无 P0/P1/P2。

## 未完成

S3.4d 尚未完成。需要复现并关闭 `K8S-OQ-017`、`021`、`022`，执行多容器双层
CPU/memory、OOM、resize、swap/hugepage/PIDs 与 ephemeral-storage 责任边界矩阵，恢复
Pod/VM/cgroup/lease 全量基线，并取得同一 reviewer 的 `APPROVE S3.4 DONE`。

## 验证

S3.4c 最终验证：`inv-886i0qgtq9` 启动即 OOM 8/8 为 `OOMKilled/137`；
`inv-v86i55g64g`/`inv-b86i5egc5x` 完成 inactive scope 删除；
`inv-a86ig40cbx`/`inv-086ig5gp25` 双 Worker exact zero；`inv-886iicgsqw` 为 3/3 Ready；
最终制品审计为 `inv-886iicgsqu`/`inv-986iicgw96`。完整证据见
[S3.4c.4 摘要](./evidence/s3.4/s3.4c.4-execution-summary.md)。

## 阻塞

无外部阻塞或待用户决策。`K8S-OQ-021` 是默认小 VM 高并发启动 `ReleasePending` 的未知
归因；`K8S-OQ-022` 是长 exec + resize 的 ttrpc/passfd 超时和状态分叉。两轮异常都已清理
至 exact zero，作为 S3.4d 第一优先级，不阻断已完成的 S3.4c。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。
云端仅操作本 PoC 创建的资源；名称带“勿删”的 CVM/TKE 不得删除。现有证据、构建产物和
回滚副本不得覆盖，handoff 不记录凭证。

## 下一步

1. 建立 S3.4d clean preflight 和固定 runner/hash。
2. 单变量复现 `K8S-OQ-021/022`，修复或冻结明确拒绝/边界语义。
3. 执行双层资源和非 cgroup 支持矩阵，清理至 exact baseline。
4. 更新证据与支持矩阵并交同一 reviewer；批准后立即进入 Kubernetes v1.36.4 E2E。
