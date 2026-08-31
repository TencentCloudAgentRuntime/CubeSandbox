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

## S3.2b RWO 持久化

### 固定输入

- 实现 commit：`6e2df6fbe20bb271e406dcb47541629c434053ac`
- 完整 tree：`fa6177d33f0a63e25be7a9e2740aa17ab7dad3a0`
- 验收脚本：`CubeShim/sandbox-probe/scripts/verify-s32b-rwo-persistence-cloud.sh`
- 脚本 SHA-256：
  `17ff8e9db7bf3922acc45245deb4dad2e574018ba7c0a68b204659b73be5b616`
- 私有 COS 对象：`s3.2b/verify-s32b-rwo-persistence-cloud-17ff8e9d.sh`
- 最终云验：`inv-983v8eg0jr`，`SUCCESS`
- 最终只读审计：`inv-983vb002pg`，`SUCCESS`
- 证据目录：
  `/data/cubelet/s3.2-evidence/s3.2b-rwo-persistence-20260831T205701Z`

### 生命周期与数据结果

验收沿用 S3.2a 的 static local、Filesystem、RWO、WaitForFirstConsumer、Retain 基线，
不增加 Cube 私有 PVC 输入：

1. 第一个 Cube Pod 的 `writer` 和 `peer` 把同一 PVC 挂到不同目标路径。四组从 CRI
   inspect 和 containerd OCI spec 提取的目标挂载记录完全一致；同一轮两个容器的
   kubelet source 相同，Guest 均看到可写 `virtiofs cubeVolumes`。writer→peer 和
   peer→writer 的写后读均成功。
2. 删除第一个 Pod 后，container、Task、Sandbox、snapshot、netns、shim、VM、share、
   mount 与 active lease 一次恢复运行时基线；该 Pod 的 kubelet 目录、shared root 和旧
   VM 路径消失。PVC/PV 仍为 `Bound`，UID 和 claimRef 未变，两个数据 marker 仍存在。
3. 以同名 Pod 重建后，Pod UID、CRI Sandbox、RuntimeResource lease、VM sandbox 路径
   和 kubelet mount source 全部变化；旧 VM 路径保持不存在。新 Pod 的两个容器读取第一
   个 Pod 写入的数据，再双向写入两个新 marker。
4. 删除第二个 Pod 后再次一次恢复运行时基线，PVC/PV 在第四个检查时点仍保持原 UID 与
   `Bound` 关系，四个 marker 均存在。随后测试清理 storage 对象和本地测试目录，完整
   Kubernetes/host/runtime 基线恢复，active lease 为 0，durable tombstone 精确增加 2。

最终证据中的 PVC UID 为 `004fe080-0c60-4f4d-9b2b-f50a96d9d9db`，PV UID 为
`f3b0ab58-c813-4395-b4e9-a65b5c5f8616`；两个 Pod UID 和 Sandbox 均不同。独立审计还
核对了脚本 SHA、三组 runtime/full baseline、四组 CRI/OCI mount、四个时点的 PV/PVC
UID 与状态、所有旧路径和固定对象消失，以及 containerd/kubelet/Node 健康。

### 失败修订与阶段边界

首轮 `inv-083v4v0pv7` 只因脚本错误假设 shared root 与 CRI Sandbox 同名而失败；诊断
`inv-683v6a05ni` 证明 `cleanup_rc=0`，固定对象、adapter、shared、reaper、VM、cleanup
record、active lease 和本地路径均无残留。修订改为解析活动期唯一的真实 shared root，
删除后按实际路径验证消失；同一 reviewer 在重跑前明确 `APPROVE`。

本阶段只证明 `static local + Filesystem + RWO` 输入下 Cube runtime 的多容器和 Pod
重建持久化语义。它不声明 CSI、动态制备、CBS/CFS、跨节点 attach、RWX、扩容或生产
可用性。同一 reviewer 对最终云验和独立审计明确 `APPROVE`；S3.2b 因此为 `DONE`。

## S3.2c 回收与故障

### 固定输入

- 实现 commit：`0bd252724523be144946f1e0f190121ff55344f7`
- 完整 tree：`68ab2419c8b8686aae6537384b3154f70ced2eef`
- 验收脚本：`CubeShim/sandbox-probe/scripts/verify-s32c-pvc-reclaim-cloud.sh`
- 脚本 SHA-256：
  `9c2bd640164dc1fd3cc8e7522d448ff67f60b8796f9484ca6963fe3e0065f1ee`
- 私有 COS 对象：`s3.2c/verify-s32c-pvc-reclaim-cloud-9c2bd640.sh`
- 最终云验：`inv-b83w9pgt64`，`SUCCESS`
- 最终只读审计：`inv-b83wguggpg`，`SUCCESS`；审计脚本 SHA-256：
  `132010c1acb7a82b65e20cb95b018856c6d00734aad40424d24e5d5e92ce665d`
- 证据目录：
  `/data/cubelet/s3.2-evidence/s3.2c-reclaim-failure-20260831T213231Z`

### 失败启动与回滚

验收创建一个同时挂载 static-local RWO PVC 和 `/dev/kvm` CharDevice hostPath 的 Cube
Pod。CRI inspect 与 containerd OCI spec 均显示 `/pvc` 位于 mount index 7，`/bad`
位于 index 8；PVC 的 source 精确指向该 Pod UID 的 kubelet local-volume 目录，两个视图
中提取的这两条目标 mount 记录完全一致。容器随后以 `StartError`、exit code 128 失败，
错误精确包含
`host bind mount source is neither file nor directory: /dev/kvm`，从而证明失败发生在 PVC
输入已进入 runtime 之后。

失败 Pod 尚未删除时，连续 30 个 100 ms 样本均确认 Task generation 和该 shared root
下的 host mount 为 0，同时 `/run/vc/vm/<sandbox>` runtime 路径仍是实际目录；这不代表
已探测 VM 进程或 Guest 健康。PV/PVC 保持原 UID 与 `Bound`，
后端 `admin-seed` 数据仍存在。证据把 shared root 的合法异步终态记录为 `present` 或
`absent-cleaned`，把 `rootfs` 和 `volumes` 分别记录为 `present-empty` 或
`absent-cleaned`；同时对 `find` 失败与目录并发消失作显式区分，不把真实遍历错误当作
清理成功。删除失败 Pod 后，runtime 集合恢复基线；后续健康
Cube Pod 使用同一 PVC 读取 `admin-seed` 并写入 `recovery-marker`，证明失败回滚没有破坏
PVC 可用性。

### Retain Released gate 与手工重绑

删除第一个 PVC 后，PV 进入 `Released`，保留旧 PVC UID 的 `claimRef` 和两个数据 marker。
显式指定同一 PV 的第二个 PVC 及其 consumer Pod 在管理员介入前连续 30 个样本保持：PVC
`Pending`、PV `Released`、Pod `Pending` 且未分配节点。保存的完整 CRI Sandbox 快照中，
该 Pod UID 的 Sandbox 数为 0。管理员移除 PV `claimRef` 后，第二个 PVC 以新 UID 绑定到
原 PV UID，Cube Pod 读取前两个 marker 并写入 `rebind-marker`；最终清理前保存的三个
SHA-256 分别按文件名对应内容独立复算通过。

三次 Pod 生命周期各生成且仅生成一条对应 Sandbox ID 的 inactive durable lease；每轮
删除后 container、Task、Sandbox、snapshot、netns、shim、VM 和 runtime resource 集合
均恢复基线。最终固定 Kubernetes 对象、kubelet Pod 目录、VM 路径、local PV 测试目录和
active lease 全部为 0，durable tombstone 精确增加 3；containerd、kubelet 保持 active，
节点 Ready 且无 DiskPressure。

### 后端边界与失败修订

本阶段验证的是 `kubernetes.io/no-provisioner`、`Retain`、`WaitForFirstConsumer` 的
static-local 手工回收。保存的测试前 Pod 清单中不存在 local volume/static provisioner，
因此 `Delete` 在该后端被标为 `NOT_APPLICABLE_WITHOUT_DELETER`，不声明自动删除；CSI、
动态制备、CBS/CFS、跨节点 attach、RWX、扩容和 VolumeSnapshot 仍未验证。

前两轮失败均为验收脚本对 runtime 异步清理形态的错误假设，而非产品残留：

- `inv-083vq60siv` 在父目录并发消失时把 `find` 结果当成错误；诊断
  `inv-083vr6gdfq` 证明 cleanup 为 0、固定对象和全部 runtime 资源为 0。
- `inv-083vusgxv0` 又错误要求 shared root 本身始终存在；诊断 `inv-883vvhgnmh`
  再次证明 cleanup 为 0，并保留了精确 mount 顺序与失败错误证据。

修订后的 `inv-983w0gg4bn` 首次完整通过；随后只增加 VM 目录、Pending 无 Sandbox 和
数据 hash 的持久证据，最终冻结为上述 SHA。独立审计先后关闭 marker 唯一性、首条
tombstone 归属和无 provisioner 基线三处伪阳性空间，`inv-b83wguggpg` 最终通过。同一
reviewer 明确 `APPROVE`；S3.2c 因此为 `DONE`，结论仍严格限于 static-local runtime
语义和 Retain 手工回收。
