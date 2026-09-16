# containerd PoC 补丁

本目录只保存 CubeSandbox Kubernetes RuntimeClass PoC 需要、但尚未进入上游
containerd 的固定版本补丁。补丁必须能用 `git apply --check` 应用于标题所标记的
containerd release，并在节点部署记录中同时固定 containerd commit、补丁 SHA-256
和最终二进制 SHA-256。

## custom sandboxer PodStats

`containerd-v2.3.4-custom-sandboxer-pod-stats.patch` 修正自定义 Sandbox Controller
下的 CRI `PodSandboxStats` 口径。标准 `podsandbox` 仍读取 Host Pod cgroup；自定义
sandboxer 仅在所有运行中容器均有完整 CPU 和 Memory 指标时，改为汇总该 Sandbox
内的 CRI 容器指标，避免把 VMM、virtiofs 和 worker 的 Host 开销计入 Pod 工作负载。
CPU/Memory 的用量、工作集、RSS 和 fault 来自 Guest 容器；CPU/Memory/IO 的 Pod
级 PSI 来自 Host Pod cgroup。后者是 kubelet 实际施加 `containers + PodOverhead`
限额以及 VMM/virtio-fs 实际发生 stall 的压力域，不能用 Guest sibling cgroup 的 PSI
代替。

应用与验证：

```bash
git checkout v2.3.4
git apply --check /path/to/containerd-v2.3.4-custom-sandboxer-pod-stats.patch
git apply /path/to/containerd-v2.3.4-custom-sandboxer-pod-stats.patch
GOFLAGS=-mod=vendor go test ./internal/cri/server -count=1
```

这是 PoC 兼容补丁，不是最终上游接口。补丁只在所有运行中容器都有完整 CPU 和
Memory 指标时聚合，Pod `AvailableBytes` 优先根据当前 sandbox resource status 中的
Pod memory limit 计算，尚未更新时回退初始 CRI `PodSandboxConfig`；指标不完整时退回
Host cgroup。兄弟容器的用量可以求和，但 PSI 不能从 sibling cgroup 合成，因此无论
单容器还是多容器，Pod PSI 都使用 Host Pod cgroup 的自然聚合；Host PSI 不可用时才
保留单容器 Guest PSI。长期方案应由 Sandbox Controller 的 `Metrics` 同时返回 Guest
Pod cgroup 用量和可关联的 Host runtime pressure，再由 containerd CRI 消费明确的混合
口径。补丁还从
core sandbox 的 `updated-resources` extension 恢复 custom sandboxer 的当前资源状态，
使 containerd 重启后的 Pod resize limit 不会退回初始值。

已知限制：只聚合当前运行中的容器，因此 init container 切换或业务容器重启后，Pod
级 `UsageCoreNanoSeconds`、`PageFaults` 等累计字段可能下降或重置。PoC 用它修正工作集、
当前 memory usage 和瞬时 CPU 等主要统计；需要单调 Pod 生命周期累计值时必须改为
Guest Pod cgroup 原生指标，不能继续从当前容器集合合成。

## Cube PodSandbox resize 转发

`containerd-v2.3.4-cube-sandbox-resize.patch` 仅对
`io.containerd.cube.rs` 生效：读取 CRI 写入 core sandbox 的
`updated-resources` extension，并通过 Sandbox shim 的 Task `Update` 转发 Pod CPU、
memory limit。CubeShim 使用绝对目标执行 VM hotplug；非 Cube runtime 保持原行为。
权威 Pod memory limit 直接作为 VM 父边界，缩容时不等待各子容器 limit 之和先降到目标；
因此其 OOM 语义是 Pod 级总量约束，不等同于逐容器 memory limit。

该补丁提供权威 Pod aggregate，适用于 containerd 2.3.4。未带补丁的 containerd
仍可通过标准容器 Task `Update` 触发 CubeShim 聚合当前 active 容器 limit，因此
1.7/2.0～2.2 无需替换节点 containerd 即可覆盖普通 app container 原地 limit 更新和
重建更新。该兜底不具备完整 Kubernetes Pod aggregate 语义：classic init container max、
Pod-level resources 以及 memory request-only 均需要本补丁提供的权威 Pod 聚合值。

应用与验证：

```bash
git checkout v2.3.4
git apply --check /path/to/containerd-v2.3.4-cube-sandbox-resize.patch
git apply /path/to/containerd-v2.3.4-cube-sandbox-resize.patch
go test ./plugins/sandbox
```

## S5.5d.1 trace 与外部 Sandbox 并行创建补丁

`containerd-v2.3.4-s34-trace.patch` 只用于 S3.4 诊断，不应进入运行时验收制品。

`containerd-v2.3.4-s55d1-perf-trace.patch` 是应用到固定 containerd v2.3.4 基线的
累积 PoC 补丁，包含两部分：

- 在 `CUBE_PERF_TRACE=1` 且 CRI RuntimeHandler 为 `cube` 时，把 RunPodSandbox、
  sandbox controller 和 Shim bootstrap 的 `CLOCK_MONOTONIC` 时间点写入 containerd
  日志；trace 默认关闭。
- 为 external shim sandboxer 增加 opt-in 配置
  `sandbox_create_before_network = true`。开启后，CRI 在创建 Pod netns 后并行执行 CNI
  ADD 与 `CreateSandbox`，在二者都成功后才执行 `StartSandbox`。Create 失败会取消 CNI；
  由该取消产生的 `context.Canceled` 不会掩盖 Create 主因，独立双失败保留两条错误链。
  CNI 失败会回滚已创建的 Sandbox；Create 成功后的 network metadata persist、pause image
  检查或 Start 失败也会同步 `ShutdownSandbox`，rollback 失败进入 containerd 的可重试
  cleanup 状态。该选项只能与 `sandboxer = "shim"` 一起使用，默认关闭，因此不会改变
  runc 或其他 runtime 的既有顺序。

CNI 和 controller 的 duration 分别在各自回调返回时结束，不包含等待另一条并行链的 join
时间；分析时必须同时保留两条偏序链，不能把重叠区间重复计费。

Cubelet 的配套实现会在 Pod netns 内等待 CNI 写入接口地址和默认路由，再创建 TAP/tc；
这使 Cube 初始化可与 CNI datapath 准备重叠，同时维持“网络就绪后才启动 Sandbox”的
对外语义。当前补丁是版本固定的 PoC 集成点，不冒充 containerd 上游接口；长期应将
通用的 external sandboxer 异步准备协议提交上游讨论，并把性能 trace 与功能改动拆开。
