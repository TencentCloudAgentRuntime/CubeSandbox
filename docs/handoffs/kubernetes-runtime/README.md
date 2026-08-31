# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.2 `IN_PROGRESS`：S3.2a 已获同一 reviewer `APPROVE` 并标记 `DONE`；当前执行 S3.2b RWO 跨容器、跨 Pod 重建持久化。

## 基线

最后一项已验证实现 commit 为 `11ada44e42f5f93af565574bed16c3561b4397be`，完整 tree 为 `44ad18ca3bf2e8bb2dd118a6b722af23ec58236e`。S3.2a 诊断脚本 SHA-256 为 `e78947213a2464d956a7427e0d3e4249314c8d0680412162bf06fb3ca14e5269`；运行时仍使用 S3.1 冻结的 shim 与 Guest 资产。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d 和 S3.2a 均为 `DONE`。S3.2a 确认自建集群没有 CSI/StorageClass，以 static local filesystem RWO PVC 隔离验证标准 bind 输入：runc 写入、Cube 读取并继续写入，CRI/OCI 完全一致，Guest 使用可写 `cubeVolumes`；Retain、对象删除和全局清理通过。同一 reviewer 明确 `APPROVE`。

## 未完成

S3.2b～S3.2d 尚未完成跨容器/跨 Pod 重建持久化、回收/故障和最终回归。CSI、动态制备、CBS/CFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 均未验证；static local 只是 runtime 语义基线，不是生产存储方案。普通 `hostPath` 仍是 `NOT_VALIDATED`，raw block 与 mountPropagation 不在 PoC 首版范围。

## 验证

S3.2a 只读盘点 `inv-083u9k0hps`、最终验收 `inv-983uns0e3g` 和最终审计 `inv-v83uqvgu6g` 均为 `SUCCESS`；证据目录为 `/data/cubelet/s3.2-evidence/s3.2a-pvc-diagnostic-20260831T203812Z`。12 组资源集合恢复基线，active lease 为 0，tombstone +1。同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s3.2/README.md`。

## 阻塞

无外部阻塞。S3.2b 采用 S3.2a 已验证的 static local filesystem RWO 基线验证 runtime 生命周期；结论不得外推为 CSI 或生产后端支持。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.2b：同一 RWO PVC 在一个 Cube Pod 的 writer/peer 间读写；删除并重建 Pod 后证明 Pod UID、Sandbox 和 VM 更换而 PVC/PV 绑定与数据保持；删除 Pod 后恢复 runtime 基线。先由同一 reviewer 审查脚本设计，云端通过后再审最终证据。
