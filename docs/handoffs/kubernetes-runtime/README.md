# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.2 `IN_PROGRESS`：S3.2a、S3.2b 已获同一 reviewer `APPROVE` 并标记 `DONE`；当前执行 S3.2c PVC 回收与失败路径。

## 基线

最后一项已验证实现 commit 为 `6e2df6fbe20bb271e406dcb47541629c434053ac`，完整 tree 为 `fa6177d33f0a63e25be7a9e2740aa17ab7dad3a0`。S3.2b 验收脚本 SHA-256 为 `17ff8e9db7bf3922acc45245deb4dad2e574018ba7c0a68b204659b73be5b616`；运行时仍使用 S3.1 冻结的 shim 与 Guest 资产。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a 和 S3.2b 均为 `DONE`。S3.2b 在同一 RWO PVC 上完成 Cube Pod 内 writer/peer 双向读写和同名 Pod 重建：Pod UID、Sandbox、lease、VM 路径与 kubelet source 更新，PVC/PV UID、Bound 关系和四个数据 marker 保持；两轮删除均恢复 runtime 基线，最终全量清理。同一 reviewer 明确 `APPROVE`。

## 未完成

S3.2c、S3.2d 尚未完成回收/故障和最终回归。CSI、动态制备、CBS/CFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 均未验证；static local 只是 runtime 语义基线，不是生产存储方案。普通 `hostPath` 仍是 `NOT_VALIDATED`，raw block 与 mountPropagation 不在 PoC 首版范围。

## 验证

S3.2b 最终云验 `inv-983v8eg0jr` 和只读审计 `inv-983vb002pg` 均为 `SUCCESS`；证据目录为 `/data/cubelet/s3.2-evidence/s3.2b-rwo-persistence-20260831T205701Z`。两轮 Pod 删除后 runtime 一次恢复，最终 active lease 为 0、tombstone +2。同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s3.2/README.md`。

## 阻塞

无外部阻塞。S3.2c 继续采用 static local filesystem RWO 基线隔离验证失败 Task、卸载、手工回收/重绑与后端边界；结论不得外推为 CSI 或动态 provisioner 的自动回收。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.2c：注入容器创建失败并证明 Task generation/mount 清零且 PVC 可继续使用；验证 Retain static local 的 Released→管理员回收→新 PVC 重绑和数据边界；记录 Delete/dynamic provisioner 不适用于该后端而不作虚假自动回收声明。同一 reviewer 审核设计和最终证据后进入 S3.2d。
