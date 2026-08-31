# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.2 `IN_PROGRESS`：S3.1 全部子阶段已获同一 reviewer `APPROVE` 并标记 `DONE`；当前执行 S3.2a filesystem PVC 输入与存储后端诊断。

## 基线

最后一项已验证实现 commit 为 `aafdef409f7d0303bf829c41509c53d0afc5321c`，完整 tree 为 `622f32e97da045bdd533a0db735249a3ba7422f4`。最终 shim SHA-256 为 `4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14`，`cube-agent.ext4` 仍为 `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`，RuntimeResource harness SHA-256 为 `7a525e8541eb774e6f80788819873c7c80fdf812eeb5b1f9d99fed20dcaf8b82`。

## 已完成

S0、S1、S2.1～S2.4 和 S3.1a～S3.1d 均为 `DONE`。S3.1d 顺序重放可写卷、失败回滚、投射卷动态更新和 subPath，并冻结 14 项支持/限制矩阵；全局资源基线精确恢复，tombstone +3，节点健康。同一 reviewer 明确确认 S3.1d 与 S3.1 可完成。

## 未完成

S3.2 尚未完成 filesystem PVC 输入、RWO 持久化、多容器与失败清理回归。普通文件/目录 `hostPath` 仍是 `NOT_VALIDATED`，raw block 与 mountPropagation 不在 PoC 首版范围。

## 验证

S3.1d 完整回归 `inv-a83u0wgvxv` 和只读审计 `inv-v83u490xa8` 均为 `SUCCESS`；编排脚本 SHA-256 为 `9df328afb0ebd833b0d3908c7e7b4fefae9bc1b5031506cea39ace9e0af60888`，汇总证据目录为 `/data/cubelet/s3.1-evidence/s3.1d-regression-20260831T201453Z`。同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s3.1/README.md`。

## 阻塞

无外部阻塞。S3.2a 需要先确认当前自建 Kubernetes 的 StorageClass/CSI 能力，再选用标准 filesystem PVC 后端；不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.2a：只读盘点当前集群 StorageClass、CSIDriver、CSINode、PV/PVC 和节点 mount 输入，选择不修改其他集群的 filesystem PVC 后端；冻结 CRI/OCI bind 输入、reclaim 与故障边界。同一 reviewer `APPROVE` 后进入 S3.2b RWO 持久化实现与验收。
