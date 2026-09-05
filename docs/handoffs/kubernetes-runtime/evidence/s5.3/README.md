# S5.3 Kubernetes NodeConformance 验收证据

## 当前状态

`DONE`。官方 477 个 `[NodeConformance]` `It` 已通过互斥分片完整执行并唯一归并，
结果为 456 Passed、17 Failed、4 Skipped；17 个失败与 4 个 Skip 均已逐项分类，测试环境
已经恢复，W1/W2 最终 exact-zero。同一 reviewer 终审 `PASS`（P0/P1/P2=0）；
完整结果见 [S5.3b/S5.3c 最终报告](./s5.3b-nodeconformance.md)。

## 固定环境与制品

- Kubernetes / kubelet：v1.36.4；containerd：2.3.4；Linux：6.6；x86_64；PVM/KVM。
- 官方 Kubernetes e2e archive SHA-256：
  `fe66edafa1595ee7bfb55bcbdf107e6dca7a7c1e59dd15ecff1f6575793f3b5b`。
- 官方 `e2e_node.test` SHA-256：
  `560a097a5aef06fe640d9bfe87d4a67dda3faafd599d7d5f028ae21fab6ec408`。
- 最终 Host runtime commit：`0e0258fb`；最终 Agent commit：`64381287`、tree
  `41297a0a1ed1eb88ff39ab0e34245278fad67ecc`。CubeShim/worker/runtime SHA-256 前缀
  分别为 `410d1799`、`3ff0b7d9`、`ea6df43e`，Agent ext4 为 `3c36bcb9…`。
- 目标节点：`cubesandbox-s0-worker` 与 `vm-200-13-ubuntu`；运行时根：
  `/opt/cubesandbox-s0-multinode-runtime-2269a3b3`。

## 为什么不能使用 containerd 缺省 Cube handler

首轮把 Cube 临时设为 containerd default runtime，并运行官方 NodeConformance。该模式
下 Pod 没有 `runtimeClassName`，kubelet 因而不会把 RuntimeClass overhead 加到 Pod
parent cgroup。15Mi OOM 用例的 parent `memory.max` 只有 15Mi，即使 CubeShim 把 VM 和
Host leaf 保持在安全下限，ancestor cgroup 仍会在 VM 启动时杀死 Shim、VMM 和 agent。
子 cgroup 无法放宽 ancestor 限制。

错误模式基线 `inv-686q27g8sp` 运行 39 项后主动终止：33 通过、6 失败。直接相关失败为
OOM、Downward API 等低内存 Pod 的 Sandbox 启动错误；另有 hostNetwork、privileged
开关和 memory EmptyDir mount identity 差异。终止后 `inv-686t0cg8dk` 确认 Sandbox、
VM、CNI/TAP、shim、mount 和 active lease 全为 0，随后恢复 default runtime=runc。

结论：正式架构必须让工作负载 Pod 显式使用 `runtimeClassName: cube`。containerd 缺省
Cube handler 不是 RuntimeClass 的等价替代，见 `K8S-OQ-024`。

## 正确测试模式

官方 `e2e_node.test` 没有全局 RuntimeClass 参数。Kubernetes v1.36 提供稳定的进程内
`MutatingAdmissionPolicy`，因此测试期创建 policy/binding，只匹配带
`e2e-framework` 标签的 namespace，并且只在 Pod 没有 runtimeClassName 时注入
`cube`。系统 namespace、auth carrier 及显式 RuntimeClass 测试对象不匹配。

`inv-b86t69gf00` 的 server-side dry-run 同时验证：

- `.spec.runtimeClassName == "cube"`；
- `.spec.overhead.memory == "256Mi"`；
- `.spec.nodeSelector["cubesandbox.io/runtime"] == "cube"`。

W1 的 containerd 仍以 runc 为 default；独立临时 import 片段仅启用 Cube privileged
开关并把官方 `test-handler` 映射到 runc。官方 helper 只用正则 `kubelet-\w+` 搜索
kubelet unit，无法识别 kubeadm 默认的 `kubelet.service`；测试期由内容等价的
`kubelet-e2e.service` 运行同一 kubelet，并读取官方测试约定的 CWD 文件
`/root/kubelet-config`；结束后恢复原 unit。该适配只服务测试环境。

## 定向门禁

### 错误 unit 名称的诊断运行

正确 RuntimeClass 注入但尚未适配 unit 名称时，10 项诊断门禁得到 2 通过、8 失败：

- OOM 用例主体已正确得到 `OOMKilled/137`，但 BeforeEach/AfterEach 因 helper 无法匹配
  `kubelet.service` 而失败；
- 三项 memory EmptyDir 的内容和 `0644` 权限正确，但 Guest `statfs` 返回
  `1702057286`（`0x65735546`，FUSE）而非 tmpfs。

### 正确 unit 名称的门禁

`inv-386td0gr45` 选择 OOM、Downward API 和 privileged HostPath/subPath 共 7 项，结果为
6 通过、1 失败：

- 所有带 NodeConformance 标签的 OOM、Downward API、privileged HostPath/subPath 门禁
  均通过；这证明 RuntimeClass overhead、Cube privileged 和 kubelet restart 路径有效。
- 唯一失败是没有 NodeConformance 标签的 NodeAllocatable Host OOM 用例：无容器 limit
  时容器 exit 1，而用例期望 Host OOM 产生 137。该 VM runtime 差异按
  `K8S-OQ-026` 延期，不阻断本次 NodeConformance。

门禁后 W1 Cube Sandbox、VM、shim、TAP、mount 和 active lease 全为 0。

### kubelet 配置改写门禁

首轮完整运行发现临时 unit 仍读取 `/var/lib/kubelet/config.yaml`，而 v1.36.4 官方
`e2e_node.test` 固定改写当前工作目录下的 `kubelet-config`。修订 unit 后，
`inv-b86w410u0n` 选择官方 `Kubelet Endpoints ... should be reflected in /configz` 单项：
1/1 通过；测试把有效值 20s 改为 30s、重启 kubelet，并在 AfterEach 恢复磁盘和有效值
为 20s。报告三件套 SHA-256 分别为 `b72dbd95…`、`829b19d7…`、`78097f0e…`。

## 已确认的非阻断差异

1. memory-backed EmptyDir 经 Host tmpfs bind + 固定 virtiofs Volume 通道进入 Guest，
   数据、mode、FSGroup、共享和清理正确，但 mount identity 为 FUSE。最终有 12 项标准
   tmpfs 类型断言失败；按 `K8S-OQ-025` 转 S6.1 设计 Guest Pod 级 tmpfs，不能伪造 statfs。
2. 首版明确不支持 hostNetwork/hostPID/hostIPC。最终有 3 个 hostNetwork 相关用例通过，
   但测试对象按准入排除规则走 runc 或只验证 API 拒绝，因此计入官方 Passed 总数、但不
   计入 Cube 可归因通过数。
3. NodeAllocatable Host OOM 的无 limit 语义不属于本次 NodeConformance 集合，按
   `K8S-OQ-026` 记录。
4. `PrivilegedPod` 暴露的 dummy netdev 缺口已关闭，不再属于已知差异，修复证据见下节。

## PrivilegedPod 修复与门禁

`f9120d79` 将 x86 BM 与 PVM Guest kernel 配置统一为内建 `CONFIG_DUMMY=y`；aarch64
原本已内建。`inv-b86w9i084p` 使用与 W1 匹配的 PVM 源 commit `0de43d6b…` 构建，最终
vmlinux 内嵌配置提取为 `CONFIG_DUMMY=y`，artifact SHA-256 为
`633bb9828e27c012ed4a0a530826ab41493401ead20750c2bd66c6d609a2dc0f`。

`inv-v86wfwg2wn` 在 W1 零 Sandbox/VM 条件下保留旧 kernel `f9ecd86a…`，再原子替换
assets target。官方 `PrivilegedPod` `inv-v86wga0nm0` 在 8.293 秒内 1/1 通过；JUnit、
Ginkgo JSON 与 output SHA-256 分别为 `4d3e29e4…`、`da8f73b7…`、`cc08067d…`。
containerd 的 Sandbox metadata 由 kubelet 异步 GC，在约 55 秒后走标准 Stop/Remove；
`inv-986wi0gicj` 确认 Sandbox/VM/shim/TAP/mount/active lease 全为 0。

## 完整运行历史

最终 dry-run 基准使用 focus `\[NodeConformance\]`，从 1197 个注册 spec 中选出 477 个
唯一 `It`。部分包含 AppArmor 环境注册的执行报告其 `PreRunStats.TotalSpecs=1201`；归并不
依赖该总数，而只接受 dry-run 的 477 个唯一键及互斥源文件分片。runner 为
`--start-services=false --stop-services=false`，凭证仅来自节点本地临时投影，不写入仓库。

- `inv-686tgvghci`，report `node-conformance-runtimeclass-full-2`：在发现执行器路径问题后
  主动 SIGINT；4856.934 秒运行 37 项，32 Passed、4 个实际 Failed、1 Interrupted。
  两个实际失败为已执行到的 tmpfs identity 差异，一个为已修复的 kubelet 配置路径，
  一个为 `PrivilegedPod` dummy netdev 缺口。中断项不计产品失败。
- `inv-986w59044s`，report `node-conformance-runtimeclass-full-3`：发现上一报告中的
  privileged 支持面问题后立即主动 SIGINT，仅运行约 2 分钟；用于避免在已知阻断上继续
  消耗数小时，不作为通过率证据。
- 重跑前 `inv-b86w4kgh72`：Sandbox/VM/lifecycle record/reaper/adapter/shared root/active
  lease/shim/TAP/mount 全部为 0；`inv-a86w4m07r2` 再次确认 RuntimeClass overhead、节点
  selector 与 W1 Ready。
- 修订 PVM Guest kernel 构建：`inv-b86w9i084p` 已完成；输入 config SHA-256
  `0d2865ad3bdd9f84ec011d41a4b2ad689808c7a5181029f7bb993db481cae4ad`，产物与门禁见上节。
- 修复后完整运行：`inv-a86wisgb60`，report
  `node-conformance-runtimeclass-full-4`，运行满 21600 秒后被 suite timeout 截断；实际执行
  398/477 项，357 Passed、41 Failed、79 未执行。Ginkgo JSON SHA-256 为
  `f641f3bb55c0c1bd822430cd054191efbe0d4291defbd56b4b5fae00e0618209`，JUnit XML
  SHA-256 为 `c0c4890656fd84420007c64ce11c1404ac22b8d0ff388422842af6ac165fb226`。
- worker 快路径最终分片执行：477/477 无遗漏、无重复，归并为 456 Passed、17 Failed、
  4 Skipped。最终 Agent 的 Device/PodResources 重跑 `inv-389w3ggrk9` 为 10/10 通过、
  1 个 SR-IOV 条件 Skip。终审中以正确 shim manager privileged 门禁精确重跑 NFS mirror
  与 non-recursive RRO，两项均进入真实业务断言后失败，最终计数不变；完整输入哈希、
  失败名称与责任层见最终报告。

## 缓存镜像 Pod 热启动诊断

`inv-9887r90bir` 在 W1 串行创建 5 个显式 `runtimeClassName: cube` 的单容器 Pod；busybox
已缓存、`imagePullPolicy=IfNotPresent`、无 init container 和 probe。client create→Ready
分别为 6476、6468、6459、6491、6474ms，平均 6474ms，镜像拉取次数为 0。同期 kubelet
增量为：`RunPodSandbox` 5 次、平均 6024ms；`CreateContainer` 5 次、平均 12ms；
`StartContainer` 5 次、平均 36ms。

CubeShim 统计中 5 次 Guest 启动到 vsock ready 为 1128～1135ms、平均 1130ms；
Cloud Hypervisor `LaunchVmm`/`BootVm` API 平均 1/18ms，Agent `CreateSandbox` 平均 7ms。
`inv-8887w0ggbr`/`inv-98880agrwj` 对额外诊断 Pod 的进程追踪显示：Cilium CNI 调用约
104ms；RuntimeResource 的 `ip/tc/TAP` 准备约 64ms；Host cgroup/lifecycle 路径执行了
264 次同步 `systemctl show`，对应反复的 stable membership 校验，是约 4.5 秒准备开销的
主因。strace 本身将该额外样本放大到 8.1 秒，因此通过未追踪的前 5 个样本报告基线，
只用追踪样本归因。

临时 namespace `cube-startup-probe-20260904-1144` 及 7 个诊断 Pod 已由
`inv-v88827gg63` 删除；`inv-b8882igpkh` 等待 containerd 异步 GC 后确认匹配的 CRI
Pod/container 均为 0。此项作为 `K8S-OQ-030` 转 S5.4，不阻断 S5.3 功能验收。

## 最终收口

1. full-4 旧失败已被最终分片替代；16 个当前架构差异、1 个 runner/环境失败和 4 个 Skip
   都有上游用例、责任层、问题 ID 与后续方案。
2. e2e namespace、临时 admission policy/binding、auth namespace、ClusterRoleBinding 和
   节点本地 token 已删除；普通 kubelet、原 CNI 与系统 workloads 已恢复。
3. 终审重跑后 W1/W2 再次均 Ready，kube-system 非 Ready Pod=0，双 Worker 的 Sandbox、
   lease、VM、TAP、mount、scope 均精确为 0；`RuntimeClass/cube` 保留供后续 S6 使用。
4. 同一 reviewer 最终审计 `PASS`（P0/P1/P2=0），`make handoff-validate` 通过，S5.3
   状态已收口为 `DONE`。
