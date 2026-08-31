# S3.1 基础 Volume 验收证据

## S3.1a 输入与现状诊断

### 范围

在同一 Kubernetes 节点上以默认 runc 为语义对照，诊断 Cube 的磁盘与内存
`emptyDir`、同卷跨容器、同卷不同目标与只读属性、ConfigMap、Secret、
projected、downwardAPI、ConfigMap `subPath`、动态更新以及删除清理行为。该子阶段
只冻结输入和缺口，不修改运行时代码。

### 资产与执行

- 诊断脚本 commit：`e0c85aab`。
- 脚本 SHA-256：`837a15dec76ed973875dd0fe260344fb3ca523220f6018d881d3c0e1c87d675f`。
- 私有 COS 对象：`kubernetes-runtime/s3.1a/diagnose-s31a-volumes-cloud-837a15dec76ed973.sh`。
- CVM：`ins-pl7mznaa`；执行：`inv-a83peh0hec`，状态 `SUCCESS`。
- 云端证据目录：`/data/cubelet/s3.1-evidence/s3.1a-diagnostic-20260831T173842Z`。
- 同一 reviewer 在脚本静态门禁和云上证据终验中均给出 `APPROVE`。

### 诊断矩阵

| 能力 | runc 对照 | Cube 当前行为 | 结论 |
|---|---|---|---|
| 磁盘 `emptyDir` 跨容器读写 | 通过 | 写入返回 `EROFS` | kubelet 输入正确，Guest 导出错误 |
| 内存 `emptyDir` 跨容器读写 | 通过 | 写入返回 `EROFS` | 与介质无关，受共享通道只读属性限制 |
| 同卷 `rw` 与 `ro` 两个目标 | `rw` 写入后可从 `ro` 别名读回，`ro` 写入失败 | 两个目标均只读 | OCI 的逐 mount `ro/rw` 被底层只读 share 覆盖 |
| ConfigMap/Secret/projected/downwardAPI 启动注入 | 通过 | 通过 | 首版启动注入路径可沿用 |
| 投射卷动态更新 | 194 秒内全部更新至 `v2` | 194 秒内全部保持 `v1` | 记入 `K8S-OQ-007`，不能声称动态更新 |
| ConfigMap `subPath` | 主卷更新后仍保持 `v1` | 保持 `v1` | 对照语义正确；Cube 尚未经历主卷更新 |

CRI inspect 与 containerd OCI spec 的标准输入逐项一致：writer 有 8 个、peer
有 3 个预期 `bind` mount。Cube 的 `/vol/work` 与 `/vol/work-ro` 使用同一 kubelet
source，options 分别为 `rbind,rprivate,rw` 和 `rbind,rprivate,ro`；`subPath` source
由 kubelet 展开为 `volume-subpaths/config/writer/7`。因此 CRI 和 kubelet 无需新增
私有 Volume API。

Guest mountinfo 直接显示 `/vol/work`、`/vol/ram` 即使 OCI 请求 `rw`，最终仍落在
`virtiofs cubeShared ro`。S3.1b 的最小实现边界由此冻结为：保留只读 rootfs
share，另设 Pod 级 Volume share；Host 端允许 kubelet 更新，Guest 端继续按每个 OCI
mount 的 `ro/rw` 约束，不能把整个 rootfs share 改为可写。

### 清理

活动期按两个 Pod UID 和 Cube shared target 采集到 29 条 host mount 记录、19 个
Cube shared target。删除后相关 mountinfo/findmnt 均为 0 行，19 个 target 逐个确认
不再挂载，两个 kubelet Pod 目录均删除。adapter、shared、reaper、cleanup、mount 和
active lease 前后均为 0；durable tombstone 精确增加 1；全量资源基线在第 62 次
100ms 轮询恢复。

## S3.1b 可写 Volume 通道

### 实现与协议

实现 commit 为 `5b504b5826c3224e33f85ea9a3761f68cdb972b1`。RuntimeResource 在每个
Sandbox 固定 shared root 下创建并校验真实目录 `volumes`；Shim 保留只读
`cube.fs` rootfs share，另向同一 Cube VM 注入 `cubeVolumes` virtio-fs，使用
`cache=none`、`read_only=false`、`announce_submounts=false`。每个 Task 把标准 OCI
bind source 导出到独立 generation，Guest source 位于
`/run/virtiofs/cubeVolumes/volumes/...`，最终 `ro/rw` 仍由逐项 OCI mount 决定。

Stop/Shutdown 先解除 Guest/VM 消费再 Release RuntimeResource；Release 失败进入可重试
的 `ReleasePending`。Task generation 在对应 Task 删除或创建失败回滚时正常清理，
Sandbox 级 RuntimeResource Release/reaper 作为最终清理兜底；固定 `volumes` inode 保持
不变。Cubelet Release 按 deepest-first 卸载，普通 unmount 失败后 detach；仍存在 active
mount 时拒绝删除 shared root。Delete 在 reaper handoff 前使用 pidfd 等待旧 shim 退出；
PID 文件确实不存在（`NotFound`）表示 VM 创建未开始，允许 handoff，而 PID 文件损坏、
不可读或其他 I/O 失败均 fail closed 并阻止 handoff。

### 构建与静态门禁

- 完整补丁从基线 `09274501dd12e47dbed2dcc77d8eb67dd661d49c` 干净回放；最终私有
  COS 对象为 `s3.1b/cubesandbox-s31b-patch-v4-f2ea6822.tar.gz`，大小 47,847
  bytes，SHA-256 为
  `f2ea6822fd50c23d66837312ff69c8d77864c09c7dec8e475ef3f205112fe44f`。
- 云端构建 `inv-a83rxbgg0g` 为 `SUCCESS`：Rust 137 项全部通过，其中显式断言
  `cube.fs cache=2/read_only=true` 与 `cubeVolumes cache=3/read_only=false`；Go
  runtime_resource race test 和 vet 通过，真实 privileged bind cleanup 为 `PASS`，
  未跳过。
- 部署的 Shim SHA-256 为
  `4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14`，
  RuntimeResource harness SHA-256 为
  `7a525e8541eb774e6f80788819873c7c80fdf812eeb5b1f9d99fed20dcaf8b82`；最终验收
  脚本 SHA-256 为
  `1133a645267a37c479dc37d5e729e84f76fcdb3b7d63ed2fd6b173c058d2972e`。

### Kubernetes 终验

终验 `inv-a83sdvgumu` 为 `SUCCESS`，证据目录为
`/data/cubelet/s3.1-evidence/s3.1b-writable-20260831T192027Z`：

- regular init、native sidecar 和 app 在同一 Pod/Cube 中完成 disk 与 memory
  `emptyDir` 的 init→sidecar→app→sidecar 双向读写；同一 disk source 的 `/vol/work`
  为 `rw`，`/vol/work-ro` 为 `ro` 且写入被拒绝。
- Guest mountinfo 显示可写卷使用 `virtiofs cubeVolumes`；容器 `/` 是只读
  `overlay2`，lowerdir 来自 Cube rootfs export。direct CRI probe 同时验证
  CreateContainer 后不产生 Task generation、StartContainer 后产生、RemoveContainer
  后恢复，并且固定 Volume share inode 全程不变。
- 故意把 char-device `/dev/kvm` 作为 bind source，使 CreateTask 在标准 rootfs 准备
  阶段失败。Kubernetes 1.36 报告 `StartError/128`；在 Sandbox VM 仍存活时，失败
  Task 的 generation 与 host mount 已均为 0。
- 主 Pod 和失败 Pod 删除后分别在 36、57 次 100ms 轮询恢复完整 baseline；container、
  Task、Sandbox、snapshot、netns、shim、VM runtime 的前后集合一致，adapter、shared、
  reaper、cleanup record、mount 与 active lease 均为 0；durable tombstone 精确增加 2。

独立只读审计 `inv-883sh80mpp` 为 `SUCCESS`，重放上述 mount、失败状态、摘要、制品
SHA 和资源集合断言；节点最终 `Ready=True`、`DiskPressure=False`、根盘使用率 56%。
同一 reviewer 对实现迭代、脚本修正和最终云证据均给出 `APPROVE`。S3.1b 因此为
`DONE`；投射卷动态更新与 subPath 进入 S3.1c。
