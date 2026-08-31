# S3.2 filesystem PVC 验收证据

## S3.2a PVC/CSI 输入诊断

### 固定输入

- 实现 commit：`11ada44e42f5f93af565574bed16c3561b4397be`
- 完整 tree：`44ad18ca3bf2e8bb2dd118a6b722af23ec58236e`
- 诊断脚本：`CubeShim/sandbox-probe/scripts/diagnose-s32a-pvc-cloud.sh`
- 脚本 SHA-256：
  `e78947213a2464d956a7427e0d3e4249314c8d0680412162bf06fb3ca14e5269`
- 私有 COS 对象：`s3.2a/diagnose-s32a-pvc-cloud-e7894721.sh`
- 云节点：本 PoC 创建的 `ins-pl7mznaa`；未修改账号内已有 TKE 集群。

### 集群存储盘点

只读盘点 `inv-083u9k0hps` 确认自建 Kubernetes client/server 均为 v1.36.4，
containerd 为 2.3.4，节点为 Linux 6.6.69；集群中没有 StorageClass、CSIDriver、
VolumeAttachment、PV/PVC 或已注册 CSI node driver，也没有存储插件 Pod。因此当前
环境不能对 CSI、动态制备、attach/detach 或云后端作已支持声明。

腾讯云当前 TKE 文档把 CBS-CSI 列为存储组件，CBS 支持静态/动态卷、拓扑、扩容、
快照与恢复；CFS-CSI 提供共享文件系统。开源
[`kubernetes-csi-tencentcloud`](https://github.com/tencentcloud/kubernetes-csi-tencentcloud)
也提供 CBS/CFS/COSFS 驱动，但其版本表只笼统标注 Kubernetes v1.14+。这些是后续
生产后端候选，不是本阶段的兼容性证据。TKE 当前组件说明见
[`CBS-CSI`](https://cloud.tencent.com/document/product/457/51099) 和
[`扩展组件概述`](https://cloud.tencent.com/document/product/457/39048)。

### 标准 PVC 输入与语义

最终验收 `inv-983uns0e3g` 为 `SUCCESS`，证据目录为
`/data/cubelet/s3.2-evidence/s3.2a-pvc-diagnostic-20260831T203812Z`；最终只读审计
`inv-v83uqvgu6g` 同样为 `SUCCESS`。验收创建一个固定节点、`Retain`、
`WaitForFirstConsumer` 的 static local filesystem PV/PVC，只用于隔离 Kubernetes PVC
输入与 Cube runtime：

1. consumer Pod 创建前，PV 为 `Available` 且没有 `claimRef`，PVC 为 `Pending` 且
   没有 `volumeName`；创建后 Kubernetes 正常绑定，PV/PVC 的名称、namespace 与 PVC
   UID 双向一致。
2. runc Pod 和随后创建的 Cube Pod 收到相同形式的 host bind：
   `/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~local-volume/`
   `cubesandbox-s32a-local-pv` 到容器 `/pvc`。CRI inspect 与 containerd OCI spec 的
   source、destination、type 和 options 完全一致；mount 记录为 `type=bind`、
   `options=rbind,rprivate,rw`。
3. runc 写入的数据由后续 Cube Pod 读到；Cube 继续写入后，Guest 中 `/pvc` 为可写
   `virtiofs cubeVolumes`。这证明标准 filesystem PVC bind 可复用 S3.1 的 Pod Volume
   通道，不需要新增 Cube 私有 PVC 协议。
4. 删除 PVC 后 PV 进入 `Released`，`Retain` 数据仍存在。测试删除所有固定对象并恢复
   本地父目录原始状态；12 组资源集合与测试前精确一致，active lease 为 0，durable
   tombstone 仅增加 1。

首轮 `inv-383uk508ki` 只因脚本把 kubelet local-volume source 后缀误写成 Pod volume
名而失败；实际规范化目录使用 PV 名。该轮 cleanup 返回 0、无残留，修正后的独立终验
与审计均通过。

### 阶段结论

S3.2a 仅冻结以下结论：`static local + Filesystem + RWO` 是可用的标准 PVC 输入和
持久性语义基线；Cube runtime 不需要识别 PVC API，只消费 kubelet 已准备并传入 CRI/OCI
的 bind mount。它不代表 local volume 是生产方案，也不代表 CSI、动态制备、CBS/CFS、
跨节点 attach、RWX、扩容或 VolumeSnapshot 已验证。后续 S3.2b/S3.2c 可在此基线上验证
runtime 生命周期，云存储后端兼容性留在 S3.2d 支持矩阵中明确标为未验证。

同一 reviewer 对 live API 约束、清理集合、绑定时序、source 目录修正与最终云证据逐轮
审查，最终明确给出 `APPROVE`；S3.2a 因此为 `DONE`。
