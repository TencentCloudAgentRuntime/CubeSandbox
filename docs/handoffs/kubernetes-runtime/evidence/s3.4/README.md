# S3.4 资源控制证据

## S3.4a 状态

`DONE`。实现、云端 V14 正式矩阵和独立审计均已通过；同一 reviewer 终审无阻断 finding，并明确给出 `APPROVE S3.4a DONE`。

## 静态输入审计

当前 Kubernetes RuntimeClass 路径有三类彼此独立的资源输入：

1. `RunPodSandbox` 的 CRI Pod 聚合资源。`runtime_resource.rs` 目前只解码 CPU period/quota/shares 和 memory limit；它们用于推导 Cube VM 的 vCPU 数与启动内存，并写成 `cube.vmmres`。同名 annotation 可以分别覆盖推导出的 CPU 或内存；缺失的另一个字段仍使用 CRI 聚合值。这里没有创建或更新 Host Pod cgroup。
2. `CreateContainer` 生成的标准 OCI `linux.resources`。CubeShim 先用 `oci-spec` 读取完整 OCI JSON，再序列化到旧 Agent protobuf。当前转换主动删除 `pids`、`blockIO`，清空 `cpu.cpus/mems`；CPU shares/quota/period、memory limit/reservation/swap 和 hugepage limits 可以进入现有 protobuf，但“可传输”不等于 Guest 已正确执行。OCI `unified`、RDMA 以及 CPU idle/burst 没有对应 protobuf 字段，当前没有无损传输契约。
3. containerd `Task.Update` 的 OCI `LinuxResources`。CubeShim 目前只转发 CPU shares/quota/period/cpus 与 memory.limit；memory reservation/swap、CPU mems、PIDs、hugepages、block I/O、RDMA、CPU idle/burst 和 unified 不会进入 Agent。即使被转发，Agent 的 cpuset 设置代码目前也被整体注释。

Guest swap 还存在两个独立风险，不能归类为“Agent 已支持”：protobuf 的 `LinuxMemory` 没有 optional presence，任一 memory message 到 Agent 后都会合成 `swappiness=Some(0)`；当前 cgroups-rs 在 cgroup v2 将 swappiness 直接写到 `memory.swap.max`。同时 Agent 的有限 memory+swap 分支没有先把 OCI 的 memory+swap 总量换算为 cgroup v2 的 swap-only 值。因此显式 swap create 可能被最后的 swappiness 写回 0，memory-limit-only Update 也可能产生 swap 副作用，必须逐阶段实测。

Cube VM 的 vCPU/内存设备规格不等同于 cgroup 限制。当前仓库未由 Cube 自行实现按 Pod 创建 Host resource envelope、设置 controller 值或在 Task Update 后重算包络。Shim runner 仍会在 containerd 显式传入 `shim_cgroup` 时加入已有 cgroup；VMM 和 virtiofs 主要在 Shim 内线程运行，云端必须采集 `/proc/$shim/task/*/{comm,cgroup}`、`shim_cgroup` 配置和继承路径，不能只扫描子进程。

## S3.4a 探针矩阵

| 路径 | 输入 | 必须保存的原始证据 | 判定目标 |
|---|---|---|---|
| 节点/版本/cgroup 基线 | 正式探针前后各采集一次 | Host/Guest kernel；Kubernetes、kubelet、containerd、runc、CubeShim、Agent 版本或 artifact SHA-256；kubelet feature gate 与资源配置；RuntimeClass overhead；Node capacity/allocatable/hugepage/swap；Host/Guest cgroup2 mount、controllers、subtree_control | 排除版本、开关、容量或 controller 委派差异造成的假结论 |
| Kubernetes 对照 | runc/Cube × BestEffort、request-only Burstable、Guaranteed | Pod JSON/status/events；containerd container/sandbox store extension 的原始 Any；实际 OCI `config.json`；CRI inspect/inspectp 辅助视图；容器内 cgroup v2 文件 | 冻结 QoS、request/limit 经 CRI、OCI 到 Host/Guest 的 create 行为 |
| 容器角色 | classic init、restartable sidecar、app | 每个角色自行写出的 `/proc/self/cgroup` 与 controller 文件 | 冻结有效 Pod 资源和逐容器资源，不用已退出 init 的事后状态推断 |
| Host 拓扑 | Cube Shim 的全部线程和实际后代；runc Host 容器 cgroup 作对照 | PID/TID/PPID/comm/命令、`/proc/$shim/task/*/{comm,cgroup}`、`/proc/PID/cgroup`、`shim_cgroup` 配置、从叶到根的 controller 文件 | 判断 containerd 的既有放置、Cube 内部线程归属和当前上限；只下结论“Cube 是否自行设置 Pod envelope” |
| 标准更新 | Kubernetes Pod `/resize` 与 containerd Task Update | 更新请求/响应；CRI 入口原始 `UpdateContainerResourcesRequest`；更新后持久化 OCI Container.Spec；实际 `UpdateTaskRequest.resources` Any；Pod allocated/actual resources；更新前后 cgroup 文件；容器 restartCount | 区分 kubelet 未发起、CRI 转换、OCI/Task 转换、Shim 丢字段、Agent 拒绝和成功更新 |
| 低层资源 | 单变量 CPU、memory limit、memory reservation、swap、cpuset、OCI PIDs、hugepage、unified | 每个变量使用独立 runc/Cube Task；保存完全相同的基准 OCI spec、实际 Create/Update Any、结果，以及 runc Host/Cube Guest 更新前后 cgroup | 一个字段拒绝不得遮蔽其他字段；定位协议、转换或执行器的精确断点 |
| ephemeral-storage | request/limit、emptyDir、writable layer 与日志目录 | Pod/CRI/OCI、kubelet 配置、节点文件系统与统计结果 | 确认其属于 kubelet/snapshotter 计量与驱逐，不伪装成 Guest cgroup |
| 拒绝路径 | 节点无容量的 hugepage、无效 unified/controller 值 | API/kubelet/containerd/Task 原始错误与零残留 | 明确 admission、CRI、Shim、Agent 各层责任 |

基线必须固定 Host/Guest kernel，以及 Kubernetes、kubelet、containerd、runc、CubeShim、Agent 的版本或 artifact SHA-256。kubelet 至少保存 `InPlacePodVerticalScaling`、`cgroupDriver`、CPU/Memory/Topology manager、`memorySwap`、`failSwapOn` 和 `podPidsLimit` 的有效值；同时保存 RuntimeClass overhead、Node capacity/allocatable、2Mi/1Gi hugepage、swap，以及 Host/Guest 的 cgroup2 mount、`cgroup.controllers`、`cgroup.subtree_control`。配置不存在时明确记录 `unset/default`，不以空输出代替结论。

高层矩阵固定为 6 个 Pod；Guaranteed 的 classic init、restartable sidecar 和 app 都显式设置相等的 CPU/memory request 与 limit，并逐 Pod 断言 `status.qosClass`。容器内至少保存 `cpu.max`、`cpu.weight`、`cpuset.cpus`、`cpuset.cpus.effective`、`cpuset.mems`、`cpuset.mems.effective`、`memory.max`、`memory.low`、`memory.swap.max`、`memory.oom.group`、`pids.max` 和可见的 `hugetlb.*.max`。

`crictl inspect/inspectp` 和 `ctr ... info` 的 JSON 只作为重建后的辅助视图，不能替代原始边界证据。正式探针必须从 containerd container/sandbox store extension 保存 `Any.type_url`、未经改写的 `Any.value`、raw bytes 与 SHA-256，并使用与现场版本固定匹配的 CRI schema 解码；container extension 的现场 key 是 `io.cri-containerd.container.metadata`，同时兼容新 key `io.containerd.cri.container.metadata`，core sandbox store extension key 是 `metadata`，legacy pause-container extension key 是 `io.containerd.cri.sandbox.metadata`。这些都是 create-time 证据，不能用其不变性推断更新请求是否发生。Cube sandbox controller 若没有对应 store extension，就在本 PoC 的 CRI 创建入口增加仅匹配探针 owner/ID 的临时 trace，不能用 inspect 结果补位。每个容器还必须从 containerd bundle 保存实际传给 runtime 的 OCI `config.json` 与 SHA-256。

更新路径必须通过仅对本探针 owner/ID 生效的临时 containerd CRI-entry trace，保存原始 `UpdateContainerResourcesRequest` 的 type/schema、raw bytes、SHA-256 和固定 schema 解码；同时保存更新后 containerd 持久化的 OCI `Container.Spec`。实际 `UpdateTaskRequest.resources` 也必须保存 `Any.type_url`、原始 value、raw request bytes、SHA-256 和固定 schema 解码。Kubernetes 路径使用上述 scoped containerd trace 和 scoped CubeShim update trace，并在执行后恢复原 binary/config；低层 helper 则先序列化并落盘自己即将发送的同一个 request，再调用 Task Update。由此按“CRI-entry trace 不存在 → kubelet 未调用；CRI 请求存在但持久化 OCI Spec 或 Task Any 缺字段 → containerd CRI/OCI/Task 转换丢失；Task Any 存在但 runtime/Guest 未生效 → Shim/Agent 执行失败”分层判定。

标准 Kubernetes 动态更新只对仍在运行的 app 和 restartable sidecar 验证 CRI/Task/Guest 更新。Kubernetes 1.36.4 接受通过 Pod `/resize` 修改已经成功退出的 classic non-restartable init container 资源字段，并把 `.status.allocatedResources` 与 `.status.resources` 更新为已接纳的新值，但不会为已终止 Task 发出 CRI/Task 资源更新。这里的 status 是 kubelet 对 non-running container 的资源记账，不表示既有已终止 task 的 runtime actual；探针必须同时保存 PodSpec 与 status 收敛、原 containerID/终止状态、无 resize condition、零 CRI/Task trace，并证明 containerd 中持久化的 create-time OCI Spec 字节未变，把它归类为 `api-spec-and-kubelet-accounting-only-terminated-task`，不能记成 runtime 缺口。

运行中容器的 create/update 输入取证必须包含 live bundle；已经成功退出的 classic init container 不保证继续保留 runc bundle，因此其 resize 后取证使用 containerd metadata store 中的持久化 Container.Spec，不把 live bundle 缺失误判为资源更新失败。

低层显式资源使用彼此独立的 containerd Task，避免把 swap、PIDs 等 Kubernetes API 不提供的字段误判为 runtime 不支持。runc 的生效证据读取 Host container cgroup，Cube 的生效证据读取 Guest per-container cgroup。swap 用例固定完全相同的 `memory.limit`，只改变 swap；memory-limit-only Update 另设用例并保存 before/after，以捕获隐式 swap 重置。

containerd `oci.GenerateSpecWithPlatform` 的低层默认 spec 不含 Kubernetes/CRI 会注入的 cgroup namespace 和 `/sys/fs/cgroup` mount；这会让 runc 和 Cube 的低层进程都无法读取 cgroup v2 controller，并非 runtime 资源执行结论。低层 helper 因此先保证恰好一个 OCI cgroup namespace，再加入与现场 CRI spec 一致的只读 `cgroup` mount（`/sys/fs/cgroup`，`nosuid,noexec,nodev,relatime,ro`），避免在共享 cgroup namespace 中重挂 cgroup2 改变共享 superblock 选项。该输入只用于观测同一进程所属 cgroup，不改变 create/update 的 `linux.resources`；runc 仍以 Host task PID leaf 为权威生效证据，Cube 仍要求 Guest mount-root-relative 解析和 self PID membership 全部通过。

所有对象使用固定 owner label/ID 前缀，清理时只删除本探针对象。除容器、Task、Sandbox、snapshot、netns、Shim、VM runtime、mount、active lease 和 kubelet Pod 目录外，还必须枚举并恢复探针创建的 Host cgroup/systemd scope 目录。精确基线同时包括 containerd、kubelet、RuntimeResource 三项服务为 active，以及 Node Ready、MemoryPressure/DiskPressure/PIDPressure 状态；前后集合和值必须一致，预检遗留或失败残留也必须单独列出。

## 云端只读预检

项目 CVM `ins-pl7mznaa` 的预检任务 `inv-084ipkgbip` 成功，冻结了正式探针的环境条件：

- Kubernetes `v1.36.4`、containerd `v2.3.4`、crictl `v1.36.0`、Linux `6.6.69`、x86_64，节点 Ready 且无 DiskPressure。
- Host 为纯 cgroup v2；根层可用并已委派 cpuset、cpu、io、memory、hugetlb、pids、rdma 等 controller。
- 节点没有 swap，kubelet `memorySwap: {}`，因此 Kubernetes 路径只验证默认 NoSwap 输入与 `memory.swap.max`；有限 swap 的数值语义必须由低层 Task 做 controller 写入验证，不能声称做了真实 swap 压力测试。
- 节点的 2Mi/1Gi hugepage capacity 与 allocatable 都是 0；Kubernetes hugepage Pod 应停在调度/准入路径。containerd 当前同时配置 `tolerate_missing_hugetlb_controller=true` 与 `disable_hugetlb_controller=true`，所以 CRI CreateContainer 会主动跳过 hugepage OCI 生成；低层 OCI Task 必须绕开 CRI，单独确认 Cube 的协议/Guest 行为。
- `crictl update` 只暴露 CPU period/quota/share、cpuset、memory 和 OOM score，不提供 swap、PIDs、hugepage 或 unified 更新参数；这些字段由低层 containerd `Task.Update` 覆盖。
- containerd、kubelet 和 RuntimeResource service 都位于各自 systemd service cgroup；Cube runtime dump 没有 `shim_cgroup` 设置。正式探针仍必须以运行中 Shim 的线程 cgroup 为准。

## 上游语义基线

- Kubernetes 1.36 的容器 CPU/内存 in-place resize 已稳定，必须通过 Pod `/resize` 子资源触发；`resizePolicy: NotRequired` 走 CRI 动态更新。
- restartable sidecar 参与 Pod 有效资源计算；Pod 级 cgroup 以 app+sidecar 总和与有效 init 峰值的较大者为基础。
- `NoSwap` 是 kubelet 默认行为，kubelet 通过 CRI 要求 runtime 设置容器级 `memory.swap.max`；是否有实际 swap 设备是另一项节点条件。
- hugepage 是容器级不可超卖资源，request 必须等于 limit，并要求节点预分配容量。
- ephemeral-storage 由 kubelet 统计 writable layer、日志和非 tmpfs `emptyDir`，超限触发驱逐；它不是 OCI cgroup controller。

参考：

- <https://v1-36.docs.kubernetes.io/docs/concepts/configuration/manage-resources-containers/>
- <https://v1-36.docs.kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/>
- <https://v1-36.docs.kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/>
- <https://v1-36.docs.kubernetes.io/docs/concepts/cluster-administration/swap-memory-management/>
- <https://v1-36.docs.kubernetes.io/docs/concepts/storage/ephemeral-storage/>
- <https://v1-36.docs.kubernetes.io/docs/tasks/manage-hugepages/scheduling-hugepages/>

## V14 固定输入与执行

- 源码包 SHA-256：`4934867f78c33c331ed91413769c27f4fa4e7e927847c6d8b1da8c774ebda9b7`；两次独立确定性归档逐字节一致。
- 私有 COS 对象：`kubernetes-runtime/s3.4a/source/cubesandbox-s34a-source-v13-4934867f.tar.gz`；只下载到本 PoC 创建的 CVM `ins-pl7mznaa`，下载校验任务 `inv-684tkdg6b7` 与固定输入切换任务 `inv-v84tkwgp0r` 均为 `SUCCESS`。
- containerd trace patch SHA-256：`19128819e0a72097e923bae6f5720938648e5368bb054989a9417744e4d5cadc`；构建/诊断/审计脚本 SHA-256 依次为 `795a2229…`、`6fbfc2ea…`、`e338332f…`。
- 云端构建 `inv-984tmbgax4` 为 `SUCCESS`，证据目录 `/data/cubelet/s3.4-evidence/s34a-build-20260901T141447Z-2438036`；trace containerd SHA-256 为 `88476ece6d2629735081bf958d3918df5ef06c34914c2f1eb840e98e279874b8`，resource helper SHA-256 为 `617492006aeb07e00fa1b22e15f0812b4d1c7eebba331cb36273d3e4b901d29c`。
- 正式运行前稳定预检 `inv-v84tnd0995` 为 `SUCCESS`：live containerd 为原始 SHA-256 `15e00263…`，三项服务 active、Node healthy，owned Pod、低层容器与 trace root 均不存在，5 秒窗口内状态稳定。
- V14 正式诊断 `inv-884tns09r5` 为 `SUCCESS`，证据目录 `/data/cubelet/s3.4-evidence/s34a-20260901T141620Z-2459937`。覆盖 6 个 Kubernetes Pod、17 个成功启动的低层 Task、1 个预期 create reject 和 2 个 invalid-unified 更新。
- 独立审计 `inv-384tqf09ng` 为 `SUCCESS`；未截断摘要由只读重跑 `inv-b84tqvg9pd` 固定为：`trace_pb=20`、`raw_create=verified`、`raw_update=verified`、`cleanup=exact`。

正式环境固定为 Kubernetes/kubelet `v1.36.4`、containerd `v2.3.4`、runc `1.4.3`、crictl `v1.36.0`、Linux `6.6.69`、amd64。CubeShim/Agent SHA-256 分别为 `3c715652…`/`87bac7a6…`。kubelet 使用 systemd cgroup driver、CPU manager `none`、Memory manager `None`、`failSwapOn=true`、`podPidsLimit=-1`；节点无 swap、无预分配 hugepage。

## V14 结论

### Kubernetes/CRI 路径

| 项目 | runc | Cube | 结论 |
|---|---|---|---|
| BestEffort/Burstable/Guaranteed | QoS 与 cgroup v2 值匹配输入；Guaranteed app 为 `cpu.max=20000 100000`、`memory.max=128Mi` | 三种 QoS 均可启动，但 app/sidecar/classic 的 Guest controller 保持默认 `cpu.max=max`、`cpu.weight=100`、`memory.max=max`、`memory.swap.max=max`、`pids.max=max` | Cube 已收到并保存标准 CRI/OCI create 输入，但现有 Guest create 未执行 per-container resources |
| running app/sidecar `/resize` | app 从 `200m/128Mi` 变为 `300m/160Mi`，sidecar 从 `100m/64Mi` 变为 `150m/80Mi`；CRI、Task 与 cgroup 前后值闭环 | Pod status 同样收敛且 CRI/Task raw trace 完整，但 Guest controller 前后全为默认值 | containerd/Kubernetes update 链路存在；缺口位于 CubeShim/Agent 的转换或 Guest 执行 |
| 已退出 classic init `/resize` | API 与 kubelet status 从 `200m` 记账为 `250m`，CRI/Task trace 均 `0→0`，持久化 create-time OCI Spec 字节不变 | 与 runc 相同 | 这是 terminated task 的 API/spec 与 kubelet accounting 行为，不是 runtime update 缺口 |
| Host 拓扑 | app/sidecar 位于各自 `kubepods.slice/.../cri-containerd-*.scope`，resize 后对应 Host leaf 更新 | Shim 全部线程及工作负载实际后代继承 `/system.slice/containerd.service`，前后 controller 均无限制 | 当前没有 Cube Pod 级 Host VM envelope，且未配置 `shim_cgroup` |
| Kubernetes hugepage | — | `2Mi` 请求在节点容量为 0 时以 `OutOfhugepages-2Mi` 失败，未创建 CRI sandbox | admission/节点容量路径正确；不能据此声明 runtime hugepage 支持 |
| ephemeral-storage | kubelet Pod 目录、emptyDir、writable layer、日志与 CRI stats 均留有原始证据 | 同左 | 责任在 kubelet、日志与 snapshotter 计量/驱逐，不进入 Guest cgroup；本阶段未做超限驱逐压力测试 |

### 低层 OCI/Task 对照

每个字段使用独立 Task，runc 以 Host task PID leaf 为权威，Cube 以 Guest self PID 所在 leaf 为权威。resource helper 给低层进程增加一个私有 cgroup namespace 和一个与 CRI 一致的只读 `/sys/fs/cgroup` mount；它不改变 `linux.resources`。

| 字段 | runc create/update | Cube create/update | S3.4b 输入 |
|---|---|---|---|
| CPU shares/quota/period | `cpu.max 50000→75000/100000`、`cpu.weight 59→100` | 调用均成功，Guest 保持 `max/100` | 实现 create 与 update |
| memory limit | `memory.max 256Mi→384Mi` | 调用均成功，Guest 保持 `max` | 实现 create 与 update |
| memory reservation | `memory.low 128Mi→256Mi`，limit 保持 `512Mi` | 调用均成功，Guest `memory.low=0`、limit `max` | protobuf create 可表达，update 当前未转发，必须补齐 |
| swap | OCI total `384Mi→512Mi` 且 limit 固定 `256Mi`，runc 正确写成 swap-only `128Mi→256Mi` | 调用均成功，Guest `memory.swap.max=max` | 修复 OCI total 到 cgroup v2 swap-only 换算及 swappiness 覆盖风险 |
| cpuset | `cpuset.cpus 0→1`、`mems=0` | 调用均成功，Guest cpuset 为空 | 恢复 Agent cpuset 执行并补齐 update mems |
| PIDs | `pids.max 128→64` | 调用均成功，Guest `max` | create protobuf 当前被 Shim 删除，update 未转发，必须补齐 |
| hugepage | runc create `0` 成功，但更新 `2Mi` 返回成功且 leaf 保持 `0`；空 create 后更新也保持 `max` | 显式 create 因错误文件名 `hugetlb..max` fail-closed；空 create 后 update 返回成功但保持 `max` | 修正 Guest page-size 到文件名映射；update 不得静默成功 |
| unified `memory.oom.group` | `0→1` | 调用成功但保持 `0` | 增加可验证白名单或明确拒绝 |
| invalid unified key | runc update 返回错误且值不变 | Cube 返回成功但值不变 | 必须 fail-closed，禁止 accepted-unapplied |

Cube 低层 Task 的 Host PID 同样位于 `/system.slice/containerd.service`；各字段变化不会形成 Host Pod/Task cgroup。由此冻结首版分层：S3.4b 先让标准 per-container 资源在 Guest create/update 生效并让不支持字段明确失败；S3.4c 再实现独立的 Host Pod VM 包络，不能把 Guest 限制误当成 Host 总量控制。

## 验收与恢复

- create-time container/sandbox store Any、实际 bundle OCI、CRI 辅助视图全部保存；update-time 原始 CRI `UpdateContainerResourcesRequest`、持久化 OCI Spec、Task `LinuxResources` Any 与 scoped Cube trace 均可按 ID 和时间窗关联。
- 6 个高层 Pod 覆盖 runc/Cube × 三种 QoS，并覆盖 classic init、restartable sidecar、app、ephemeral-storage 和 running/terminated resize；低层矩阵逐字段隔离，拒绝不会遮蔽后续场景。
- 所有 cgroup 读数均验证唯一 cgroup2 mount、mount-root-relative 路径和 self PID membership；runc 另以 Host task PID 与 live `cgroup.procs` membership 交叉核对。
- 正式脚本结束时 baseline 首次比较即匹配；原始 containerd 恢复，containerd/kubelet/RuntimeResource 三项服务 active，Node Ready 且无 Memory/Disk/PIDPressure，owned Pod、Task、Sandbox、snapshot、mount、netns、Shim、VM、trace root 与新增 active lease 均无残留。
- V12/V13 失败轮次也完成精确恢复。V12 暴露 hugepage 成功返回与 leaf 实际值不能等同；V13 暴露低层默认 OCI 缺少 cgroup namespace/mount。两项均先修正探针并经同一 reviewer 批准，再进入 V14。

S3.4a 只冻结输入、现状与精确缺口，不把“请求被接受”记成能力支持，也不提前声明压力/OOM/驱逐语义完成。

## 待关闭

- `K8S-OQ-014`：Host Pod VM 包络的进程归属、计算输入与 overhead 处理。
- `K8S-OQ-015`：Guest 更新和 Host 包络重算的顺序、幂等键与失败恢复。
- `K8S-OQ-016`：swap、PIDs、hugepage 的 Guest/Host 分层，以及 ephemeral-storage 的 kubelet 边界。
