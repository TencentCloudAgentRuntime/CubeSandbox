# S3.4 资源控制证据

## S3.4a 状态

`DONE`。V15 已用实际 `RuntimeClass`、containerd `Runtime.Name` 和 PID membership 锚定运行时身份，同时读取 Cube resource parent 与 `runtime` process leaf；正式矩阵与独立审计均通过，同一 reviewer 已确认 `APPROVE S3.4a DONE`。V14 的 Guest 支持结论保持撤回，仅保留其历史执行记录。

## 静态输入审计

当前 Kubernetes RuntimeClass 路径有三类彼此独立的资源输入：

1. `RunPodSandbox` 的 CRI Pod 聚合资源。`runtime_resource.rs` 目前只解码 CPU period/quota/shares 和 memory limit；它们用于推导 Cube VM 的 vCPU 数与启动内存，并写成 `cube.vmmres`。同名 annotation 可以分别覆盖推导出的 CPU 或内存；缺失的另一个字段仍使用 CRI 聚合值。这里没有创建或更新 Host Pod cgroup。
2. `CreateContainer` 生成的标准 OCI `linux.resources`。CubeShim 先用 `oci-spec` 读取完整 OCI JSON，再序列化到旧 Agent protobuf。当前转换主动删除 `pids`、`blockIO`，清空 `cpu.cpus/mems`；CPU shares/quota/period、memory limit/reservation/swap 和 hugepage limits 可以进入现有 protobuf，但“可传输”不等于 Guest 已正确执行。OCI `unified`、RDMA 以及 CPU idle/burst 没有对应 protobuf 字段，当前没有无损传输契约。
3. containerd `Task.Update` 的 OCI `LinuxResources`。CubeShim 目前只转发 CPU shares/quota/period/cpus 与 memory.limit；memory reservation/swap、CPU mems、PIDs、hugepages、block I/O、RDMA、CPU idle/burst 和 unified 不会进入 Agent。即使被转发，Agent 的 cpuset 设置代码目前也被整体注释。

Guest swap 还存在两个独立风险，不能归类为“Agent 已支持”：protobuf 的 `LinuxMemory` 没有 optional presence，任一 memory message 到 Agent 后都会合成 `swappiness=Some(0)`；当前 cgroups-rs 在 cgroup v2 将 swappiness 直接写到 `memory.swap.max`。同时 Agent 的有限 memory+swap 分支没有先把 OCI 的 memory+swap 总量换算为 cgroup v2 的 swap-only 值。因此显式 swap create 可能被最后的 swappiness 写回 0，memory-limit-only Update 也可能产生 swap 副作用，必须逐阶段实测。Kubernetes 高层 create OCI 还会在 `unified` 中携带 `memory.swap.max=0`，但旧 Agent protobuf 无法表示 `unified`；Cube parent 最终观测为 `0` 是上述 `LinuxMemory` presence/`swappiness=0` 副作用偶然满足 NoSwap 结果，不能证明该 key 已无损传输。S3.4b 修复 presence 时必须同时无损处理或白名单实现 `memory.swap.max`，并保持 Kubernetes NoSwap 回归。

CPU shares 也不能只以“weight 发生变化”判定兼容。Agent 当前使用旧线性公式 `1+((shares-2)*9999)/262142`；现场 containerd/runc 使用 `github.com/containerd/cgroups/v3@v3.1.3` 的 `ConvertCPUSharesToCgroupV2Value` 对数/二次映射，并保持 `shares=1024 → weight=100` 的默认点。S3.4a 必须逐个保存同一 OCI shares 的 runc/Cube weight，S3.4b 再决定统一到当前 containerd 语义，不能把旧公式直接标为支持。

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

## V15 修正输入与执行

- 源码包 SHA-256：`d4400132b78c3af1f11386aea1be88fa9a5848687a2dc22352ff8e15a395c9a9`；两次独立确定性归档逐字节一致。私有 COS 对象为 `kubernetes-runtime/s3.4a/source/cubesandbox-s34a-source-v14-d4400132.tar.gz`。
- reviewer 冻结并批准的 main/test/diagnose/audit SHA-256 依次为 `2822a49e9f2285044289490cf2e875deccc8cf0d8155b6765a8ad7c65f8812d5`、`ee7db4f8aa98bf89d52b4699ea4f5e520fd30b2862ee27f5d6bc80cd441864c3`、`3f725985865609310f71e5a8be5ead9c7cb11e3cc8e59b806ee1f6603c8a712e`、`b6831d879216b9c8cec1b378e4d7a377f8651ccc5c8eec64a8ae33f323b8c8e5`。源码、diagnose、audit 下载校验任务分别为 `inv-b84ut0g7ij`、`inv-984ut1g29a`、`inv-a84ut0gkt7`，固定输入切换 `inv-v84utv0jmw`；全部只作用于本 PoC CVM `ins-pl7mznaa` 且为 `SUCCESS`。
- 云端构建 `inv-984uubgkt5` 为 `SUCCESS`，证据目录 `/data/cubelet/s3.4-evidence/s34a-build-20260901T145623Z-2515543`；trace containerd SHA-256 为 `88476ece6d2629735081bf958d3918df5ef06c34914c2f1eb840e98e279874b8`，新 resource helper SHA-256 为 `242a68a8451ea19ccba65b9d58133f732b2944afc5923a029be7d4b431cd5a44`。
- 稳定清洁预检 `inv-b84uvagqkj` 为 `SUCCESS`：live containerd 为原始 SHA-256 `15e00263…`，三项服务 active、Node healthy，无 owned Pod、低层容器或 trace root，5 秒窗口状态稳定。
- V15 正式诊断 `inv-084uvpg3h5` 为 `SUCCESS`，证据目录 `/data/cubelet/s3.4-evidence/s34a-20260901T145751Z-2537408`：`highlevel=6`、`lowlevel_started=17`、`expected_create_reject=1`、`cleanup=exact`。
- 独立审计 `inv-384uxu0pj7` 为 `SUCCESS`；未截断只读重跑 `inv-084v08g9um` 固定摘要为：`invalid_unified=2`、`trace_pb=20`、`raw_create=verified`、`raw_update=verified`、`cleanup=exact`。父/子/Host 三层紧凑值由只读任务 `inv-a84v15g4av` 提取，OCI 输入由 `inv-884v2703dm` 提取，二者均为 `SUCCESS`。
- 为便于无云权限 reviewer 独立复核，三项 TAT 完整 stdout 已原样保存为 [`v15-cgroup-result-summary.txt`](./v15-cgroup-result-summary.txt)、[`v15-oci-input-summary.txt`](./v15-oci-input-summary.txt) 和 [`v15-audit-summary.txt`](./v15-audit-summary.txt)，SHA-256 依次为 `1cfe651ff4f2356b0ab1209564c3700eddd65bbfb51942f5dca032f170d1370e`、`323917c516621868fd220a64801419b35646d88af5f8ea955581b786f2ee011a`、`8f929ecab4c6a8e047ff5d2a2b2d7732b68b23a5d2ea441d0798a7b9e4ed59cf`；文件不含凭据、签名 URL 或 secret。
- reviewer 要求补查的 memory-limit-only swap 三层值由只读任务 `inv-884v8ngwt7` 提取，完整 stdout 保存为 [`v15-memory-limit-swap-summary.txt`](./v15-memory-limit-swap-summary.txt)，SHA-256 为 `ddc5e4c5392d5e0bd00ca9dca5af0155b179182ee8c13a47ca1f2fbc44962d48`。

正式环境与 V14 相同：Kubernetes/kubelet `v1.36.4`、containerd `v2.3.4`、runc `1.4.3`、crictl `v1.36.0`、Linux `6.6.69`、amd64，CubeShim/Agent SHA-256 为 `3c715652…`/`87bac7a6…`。

## V14 历史执行

- 源码包 SHA-256：`4934867f78c33c331ed91413769c27f4fa4e7e927847c6d8b1da8c774ebda9b7`；两次独立确定性归档逐字节一致。
- 私有 COS 对象：`kubernetes-runtime/s3.4a/source/cubesandbox-s34a-source-v13-4934867f.tar.gz`；只下载到本 PoC 创建的 CVM `ins-pl7mznaa`，下载校验任务 `inv-684tkdg6b7` 与固定输入切换任务 `inv-v84tkwgp0r` 均为 `SUCCESS`。
- containerd trace patch SHA-256：`19128819e0a72097e923bae6f5720938648e5368bb054989a9417744e4d5cadc`；构建/诊断/审计脚本 SHA-256 依次为 `795a2229…`、`6fbfc2ea…`、`e338332f…`。
- 云端构建 `inv-984tmbgax4` 为 `SUCCESS`，证据目录 `/data/cubelet/s3.4-evidence/s34a-build-20260901T141447Z-2438036`；trace containerd SHA-256 为 `88476ece6d2629735081bf958d3918df5ef06c34914c2f1eb840e98e279874b8`，resource helper SHA-256 为 `617492006aeb07e00fa1b22e15f0812b4d1c7eebba331cb36273d3e4b901d29c`。
- 正式运行前稳定预检 `inv-v84tnd0995` 为 `SUCCESS`：live containerd 为原始 SHA-256 `15e00263…`，三项服务 active、Node healthy，owned Pod、低层容器与 trace root 均不存在，5 秒窗口内状态稳定。
- V14 正式诊断 `inv-884tns09r5` 为 `SUCCESS`，证据目录 `/data/cubelet/s3.4-evidence/s34a-20260901T141620Z-2459937`。覆盖 6 个 Kubernetes Pod、17 个成功启动的低层 Task、1 个预期 create reject 和 2 个 invalid-unified 更新。
- 独立审计 `inv-384tqf09ng` 为 `SUCCESS`；未截断摘要由只读重跑 `inv-b84tqvg9pd` 固定为：`trace_pb=20`、`raw_create=verified`、`raw_update=verified`、`cleanup=exact`。

正式环境固定为 Kubernetes/kubelet `v1.36.4`、containerd `v2.3.4`、runc `1.4.3`、crictl `v1.36.0`、Linux `6.6.69`、amd64。CubeShim/Agent SHA-256 分别为 `3c715652…`/`87bac7a6…`。kubelet 使用 systemd cgroup driver、CPU manager `none`、Memory manager `None`、`failSwapOn=true`、`podPidsLimit=-1`；节点无 swap、无预分配 hugepage。

## V15 修正结论

V15 的每个 Cube capture 都满足 scoped view 中 `resource=/`、`process=/runtime`，self PID 只存在于 process leaf，resource parent 不含该 PID；实际 Pod `RuntimeClass`、sandbox/container 的 containerd `Runtime.Name` 同时与目录标签一致。Agent 把资源写在 parent，再把进程放入 child；因此以下无前缀值是权威资源值，`process.*` 默认值只是子层没有叠加第二重限制，不能再据此判定父层未生效。

### Kubernetes/CRI 路径

| 项目 | runc | Cube | 结论 |
|---|---|---|---|
| BestEffort/Burstable/Guaranteed | QoS 与 create 输入闭环；shares `51/102/204` 对应 weight `11/17/29`；Guaranteed app 为 `cpu.max=20000 100000`、`memory.max=128Mi` | 三种 QoS 的 classic/sidecar/app 均启动；parent 的 quota 和 memory limit 匹配 OCI，但旧线性 shares 映射给出 `51/102/204→2/4/8` | create-time quota 与 `memory.max` 已生效；period 输入和结果均为默认 `100000`，未独立证明；shares 已传输/写入但与当前 runc 映射不兼容；unified 的 `memory.oom.group=1` 和 `memory.swap.max=0` 均未进入 Agent，后者仅被 memory presence 副作用偶然满足 |
| running app/sidecar `/resize` | app 从 `200m/128Mi` 变为 `300m/160Mi`，weight `29→40`；sidecar从 `100m/64Mi` 变为 `150m/80Mi`，weight `17→24`；CRI、Task 与 cgroup 前后值闭环 | app parent 为 `cpu.max 20000→30000/100000`、旧线性 weight `8→12`、`memory.max 128Mi→160Mi`；sidecar为 `10000→15000/100000`、`4→6`、`64Mi→80Mi` | quota 与 `memory.max` update 已生效；period 前后都是默认 `100000`，未独立证明 update；shares update 会写值但映射仍不兼容，必须进入 S3.4b |
| 已退出 classic init `/resize` | API 与 kubelet status 从 `200m` 记账为 `250m`，CRI/Task trace 均 `0→0`，持久化 create-time OCI Spec 字节不变 | 与 runc 相同 | 这是 terminated task 的 API/spec 与 kubelet accounting 行为，不是 runtime update 缺口 |
| Host 拓扑 | app/sidecar 位于各自 `kubepods.slice/.../cri-containerd-*.scope`，resize 后对应 Host leaf 更新 | Shim 全部线程及工作负载实际后代继承 `/system.slice/containerd.service`，前后 controller 均无限制 | 当前没有 Cube Pod 级 Host VM envelope，且未配置 `shim_cgroup` |
| Kubernetes hugepage | — | `2Mi` 请求在节点容量为 0 时以 `OutOfhugepages-2Mi` 失败，未创建 CRI sandbox | admission/节点容量路径正确；不能据此声明 runtime hugepage 支持 |
| ephemeral-storage | kubelet Pod 目录、emptyDir、writable layer、日志与 CRI stats 均留有原始证据 | 同左 | 责任在 kubelet、日志与 snapshotter 计量/驱逐，不进入 Guest cgroup；本阶段未做超限驱逐压力测试 |

### 低层 OCI/Task 对照

每个字段使用独立 Task。runc 的 resource/process 是同一 leaf，并以 Host task PID leaf 再次交叉验证；Cube 的 resource parent 与 process leaf 分离，parent 值是权威限制，process leaf 保持默认值时仍受父层层级约束。resource helper 的私有 cgroup namespace 和只读 cgroup mount 只用于观测，不改变 `linux.resources`。

| 字段 | runc create/update | Cube create/update | S3.4b 输入 |
|---|---|---|---|
| CPU shares/quota/period | 同一 OCI shares `512→1024` 得到 weight `59→100`，`cpu.max 50000→75000/100000` | quota 正确；period 输入和结果始终为默认 `100000`；旧线性映射只得到 weight `20→39` | quota 已支持；period 尚未独立证明，S3.4b 增加非默认 period 的 create/update；shares create/update 虽写入但与当前 cgroups v3/runc 不兼容，需统一转换并回归默认点与代表值 |
| memory limit | `memory.max 256Mi→384Mi`，未指定 swap 时 `memory.swap.max=max→max` | `memory.max 256Mi→384Mi`，但未指定 swap 在 create 时已被隐式写为 `0`，update 后仍为 `0` | `memory.max` 数值更新已支持；修复 protobuf presence/swappiness，使 limit-only create/update 都不改变 swap，并用非零 swap 基线验证 update |
| memory reservation | `memory.low 128Mi→256Mi`，limit 保持 `512Mi` | create 正确写 `128Mi`；update 返回成功但仍为 `128Mi` | create 已支持；补齐 update 转发，禁止静默未应用 |
| swap | OCI total `384Mi→512Mi` 且 limit 固定 `256Mi`，runc 正确写成 swap-only `128Mi→256Mi` | parent create/update 都为 `0`，既不等于初始 `128Mi`，也没有更新为 `256Mi` | 修复 create 的 total→swap-only 与 swappiness 覆盖，并补齐 update |
| cpuset | `cpuset.cpus 0→1`、`mems=0` | parent create/update 都为空 | 恢复 Agent cpuset 执行，update 同时转发 cpus/mems |
| PIDs | `pids.max 128→64` | parent create/update 都为 `max` | create 不得删除 PIDs，update 必须转发 |
| hugepage | runc create `0` 成功，但更新 `2Mi` 返回成功且 leaf 保持 `0`；空 create 后更新也保持 `max` | 显式 create 因错误文件名 `hugetlb..max` fail-closed；空 create 后 update 返回成功但保持 `max` | 修正 Guest page-size 到文件名映射；update 不得静默成功 |
| unified `memory.oom.group` / `memory.swap.max` | `memory.oom.group 0→1`；Kubernetes NoSwap create 输入包含 `memory.swap.max=0` | `memory.oom.group` 调用前后均为 `0`；两个 unified key 都没有 protobuf 表示，NoSwap 的 parent `0` 仅由 memory presence 副作用偶然产生 | 增加可验证白名单与协议表示，或对无法表示值明确拒绝；presence 修复后必须保持 Kubernetes NoSwap 回归 |
| invalid unified key | runc update 返回错误且值不变 | Cube 返回成功但值不变 | 必须 fail-closed，禁止 accepted-unapplied |

Cube 低层 Task 的 Host PID 同样位于 `/system.slice/containerd.service`；各字段变化不会形成 Host Pod/Task cgroup。由此冻结首版分层：S3.4b 先让标准 per-container 资源在 Guest create/update 生效并让不支持字段明确失败；S3.4c 再实现独立的 Host Pod VM 包络，不能把 Guest 限制误当成 Host 总量控制。

## 验收与恢复

- create-time container/sandbox store Any、实际 bundle OCI、CRI 辅助视图全部保存；update-time 原始 CRI `UpdateContainerResourcesRequest`、持久化 OCI Spec、Task `LinuxResources` Any 与 scoped Cube trace 均可按 ID 和时间窗关联。
- 6 个高层 Pod 覆盖 runc/Cube × 三种 QoS，并覆盖 classic init、restartable sidecar、app、ephemeral-storage 和 running/terminated resize；低层矩阵逐字段隔离，拒绝不会遮蔽后续场景。
- 所有 cgroup 读数均验证唯一 cgroup2 mount、mount-root-relative 路径和 self PID membership；V15 额外强制 Cube `<resource>/runtime` 父子路径、parent non-self、process self、两层 controller 唯一值和实际 containerd runtime identity，runc 另以 Host task PID 与 live `cgroup.procs` membership 交叉核对。
- 正式脚本结束时 baseline 首次比较即匹配；原始 containerd 恢复，containerd/kubelet/RuntimeResource 三项服务 active，Node Ready 且无 Memory/Disk/PIDPressure，owned Pod、Task、Sandbox、snapshot、mount、netns、Shim、VM、trace root 与新增 active lease 均无残留。
- V15 正式运行与独立审计均确认原始 containerd 恢复、三项服务健康、`cleanup=exact`。V12/V13 失败轮次也完成精确恢复；V14 暴露了 resource parent/process leaf 取证错误并被撤回，没有把错误结论带入实现阶段。

S3.4a 只冻结输入、现状与精确缺口，不把“请求被接受”记成能力支持，也不提前声明压力/OOM/驱逐语义完成。

## S3.4b Guest per-container cgroup

状态：`DONE`。最终实现基线为 `be8e7304`；同一 reviewer 已完成本地独立复跑和证据审计，并明确给出 `APPROVE S3.4b DONE`。

- `inv-8853vxgxh1`：17 组 runc/Cube create/update 数值对照、10 个 shares 向量、21 个 invalid update、4 个 invalid create 与 exact cleanup 通过。非默认 CPU period、reservation、swap、cpuset、PIDs、hugepage 和 unified 白名单均生效；unsupported 输入 fail-closed。
- `inv-k852mwg8ud`：在真实 Host cgroup v2 目录注入 write/readback/rollback fault，journal replay 后 controller 原值恢复，测试目录删除。
- `inv-9855pngtst`：CPU throttle/unlimited、PIDs fork EAGAIN、稳定 96MiB OOM exit 137、checkBeforeUpdate 正反例、hugepage 配置、20 个 partial update、changed-device reject、PendingCreate 同 ID retry、survivor 和 exact cleanup 通过。
- `inv-08564809p0`：Agent 缺少 capability 和 version=0 均在首个 task 前失败，逐项恢复 baseline，并恢复 canonical Agent。
- `inv-68569j047d`：new Shim/new Agent 与 old Shim/new Agent 各连续 20 次，标准 rootfs 和动态 mount 均通过且精确清理，canonical Shim 恢复。
- `inv-v856bt07f9`：实际 `RuntimeClass` 两容器 Pod 原地 resize；app weight `29→40`、memory `64Mi→96Mi`，Pod UID/IP、Sandbox、container ID、Shim start、VM inode 和 survivor controller 保持，删除后 14 类基线精确恢复。
- `inv-6856c8gt1t`：最终独立预检 `cube_pods=0 lowlevel=0 vm=0 shim=0 active_leases=0`。

固定 live CubeShim/Agent SHA-256 为 `398416c5…`/`2e3318e6…`。完整 invocation 输出、目录摘要、OOM/controller 读数和逐类 cleanup 哈希见 [`s3.4b-execution-summary.txt`](./s3.4b-execution-summary.txt)、[`s3.4b-runtime-behavior-summary.txt`](./s3.4b-runtime-behavior-summary.txt) 和 [`s3.4b-cleanup-hashes.txt`](./s3.4b-cleanup-hashes.txt)，文件 SHA-256 依次为 `af5d8627…`、`68253edb…`、`a0076216…`。

边界：checkBeforeUpdate=false 且把 `memory.max` 猛降到远低于当前用量时，内核 reclaim 可能超过 Shim-Agent 10 秒 RPC；失败诊断已隔离且最终节点清洁，但该极端路径没有记成通过能力，转入 `K8S-OQ-017`。S3.4b 通过范围是写前拒绝、unchecked 有界下调和稳定 limit 下的 OOM 语义。

## S3.4c.1 Host Pod VM 包络设计

状态：`DONE`。冻结设计见 [`s3.4c-design.md`](./s3.4c-design.md)，紧凑证据见
[`s3.4c-design-evidence.txt`](./s3.4c-design-evidence.txt)。同一 reviewer 进行了四轮复审，最终
明确返回 `APPROVE S3.4c DESIGN`。

- kubelet 独占 Pod parent，Cube leaf 只表达静态 VM capacity 加 RuntimeClass overhead，Guest
  Agent 继续独占 per-container cgroup；动态 resize 不依赖 containerd sandbox Update。
- managed/legacy classification、OCI cgroup path、bootstrap gate、immutable/containment identity、
  pidfd、bundle 外 takeover record、长期 watchdog 和全局 socket cleanup 契约已冻结。
- lifecycle 在首次 mutation 前建立 HostCgroup/RuntimeResource canonical owners；cleanup 必须
  先 revoke operation-owner epoch、把两个 owner durable handoff，再停止精确 server identity。
- controller 使用 INTENT-before-write WAL、唯一 owner/epoch、operation lock 与封闭恢复决策表；
  RuntimeResource 每项分配也必须先持久化可 reconcile 的 allocation INTENT。
- `inv-38589x0k30` 在目标 systemd `255.4-1ubuntu8` 对
  `PIDs + Delegate + CollectMode=inactive-or-failed` 连续执行 200 次，结果 `failures=0`、
  `left_units=0`、`left_cgroups=0`、`cleanup=exact` 且 TAT `dropped=0`。该结果只覆盖当前
  package/build/boot，新环境仍须重新门禁。

## 待关闭

- `K8S-OQ-014`：Host Pod VM 包络的进程归属、计算输入与 overhead 处理。
- `K8S-OQ-015`：Guest 更新和 Host 包络重算的顺序、幂等键与失败恢复。
- `K8S-OQ-016`：swap、PIDs、hugepage 的 Guest/Host 分层，以及 ephemeral-storage 的 kubelet 边界。
- `K8S-OQ-017`：极端 unchecked `memory.max` 下调的阻塞写、RPC deadline 与最终状态对账。

## 额外多节点交互基线（2026-09-02）

额外 TKE `cls-1oqe2py4` 的两个节点、Deployment 5 副本、StatefulSet 3 副本及
逐 Pod HTTP/curl 验收已经通过。该集群当前使用 TKE 默认 containerd，不计作 Cube
RuntimeClass 的 S3.4c 验收；资源清单、TAT 证据和用户验证命令见
[`extra-two-node-cluster.md`](./extra-two-node-cluster.md)。

## S0 Cube RuntimeClass 跨节点回归（2026-09-02）

S0 三节点自建集群的两个 PVM 工作节点已使用 `RuntimeClass/cube` 运行 Deployment 5
副本和 StatefulSet 3 副本。8 个 Pod 实际对应 8 个 `io.containerd.cube.rs` sandbox/VM；
64 次 PodIP 全互访、30 次跨节点、24 次稳定 DNS、24 次 ClusterIP 以及非 root resolver
读取和 root 只读写保护全部通过。工作负载按用户要求保留运行；修正、制品 SHA、TAT
证据和人工复查命令见
[`s0-cube-crossnode-workloads.md`](./s0-cube-crossnode-workloads.md)。该回归扩充
S3.4c.2 证据，但不代替尚未完成的 sibling/PID 诱饵、containerd restart 和 legacy Task。
2026-09-03 又以同一 `2269a3b3` 源码补齐两个 Worker 的 `cube-runtime` CLI；两节点
SHA 一致，安装未重启 containerd，8 Pod/8 次 Service DNS 回归保持通过，详细制品身份、
TAT 任务和失败尝试边界记录在同一证据页。
