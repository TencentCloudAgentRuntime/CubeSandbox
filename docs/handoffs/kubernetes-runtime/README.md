# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.2 `IN_PROGRESS`：S3.2a～S3.2c 已获同一 reviewer `APPROVE` 并标记 `DONE`；当前执行 S3.2d 回归与支持矩阵。

## 基线

最后一项已验证实现 commit 为 `0bd252724523be144946f1e0f190121ff55344f7`，完整 tree 为 `68ab2419c8b8686aae6537384b3154f70ced2eef`。S3.2c 验收脚本 SHA-256 为 `9c2bd640164dc1fd3cc8e7522d448ff67f60b8796f9484ca6963fe3e0065f1ee`；运行时仍使用 S3.1 冻结的 shim 与 Guest 资产。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a～S3.2c 均为 `DONE`。S3.2c 证明 PVC 已进入 runtime 后的精确启动失败会清空 Task generation/mount；取证时 VM runtime 目录仍存在且 PVC 数据保持，健康 Pod 可继续复用。static-local Retain PV 经 Released gate 和管理员移除 claimRef 后可绑定新 PVC UID 并保持三个 marker。三次生命周期均恢复 runtime 基线，最终全量清理。同一 reviewer 明确 `APPROVE`。

## 未完成

S3.2d 尚未完成最终组合回归和支持矩阵。CSI、动态制备、CBS/CFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 均未验证；static local 只是 runtime 语义基线，不是生产存储方案。普通 `hostPath` 仍是 `NOT_VALIDATED`，raw block 与 mountPropagation 不在 PoC 首版范围。

## 验证

S3.2c 最终云验 `inv-b83w9pgt64` 和收紧后的只读审计 `inv-b83wguggpg` 均为 `SUCCESS`；证据目录为 `/data/cubelet/s3.2-evidence/s3.2c-reclaim-failure-20260831T213231Z`。失败回滚、健康复用、Released negative gate、手工重绑、三个数据 hash 和三条 Sandbox tombstone 均被独立核对；最终 active lease 和所有固定残留为 0。同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s3.2/README.md`。

## 阻塞

无外部阻塞。S3.2d 必须组合重放 S3.2a～S3.2c 的 filesystem PVC 主路径并冻结支持矩阵；static-local Delete 在没有 deleter 时为不适用，CSI/dynamic/CBS/CFS 等未实测项必须保持未验证，不得从 static-local 结果外推。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.2d：定义并运行覆盖 S3.2a～S3.2c 冻结输入、RWO 持久化、失败回滚和 Retain 手工重绑的组合回归；核对全量资源基线；生成 filesystem PVC 支持矩阵，把 RWO/static-local 已验证项与 CSI、dynamic、CBS/CFS、RWX、扩容、snapshot 等未验证项分开。同一 reviewer 审核设计和最终证据后再关闭 S3.2。
