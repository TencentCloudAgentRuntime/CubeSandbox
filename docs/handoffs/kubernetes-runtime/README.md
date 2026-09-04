# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S5.4a `IN_PROGRESS`，S5.3a `VALIDATING`。最新计划先短回归已有 SIGKILL、sysctl、cpuset
和 sidecar 修复，再冻结一秒 SLO 与 `CubeShim → cube-vmm-worker` 进程/所有权边界；完成
worker 拆分和普通启动优化后收口 Node E2E，随后进入需要用户确认的 Snapshot 设计与实现，
最终在快照快路径同时关闭一秒门禁和 Node E2E。首轮 477 项 full-4 的 357/41/79 仍只是旧
嵌入式 VMM 基线，不是最终验收轮。

## 基线

最后一项已完成云端构建验证的实现 commit 为 `8dc39f77`；最新任务重排 commit 为
`2681b641`；S3.4c 最终证据 commit 为 `24d2d188`。W1 尚未部署本轮候选，当前 CubeShim/Agent ext4 SHA-256 为
`e0052c7e…`/`c768706b…`；`cube-runtime`
保持既有制品；运行时根为
`/opt/cubesandbox-s0-multinode-runtime-2269a3b3`。W1 PVM Guest kernel SHA-256 为
`633bb982…`，旧 `f9ecd86a…` 已保留为可回滚副本。

## 已完成

S0、S1、S2、S3.1～S3.4d 均为 `DONE`。S3.4d 已关闭
`K8S-OQ-015/016/017/021`，完成生命周期 fence、受控 restart/resize/long-exec、
ephemeral-storage、QoS/多容器双层数值和最终清理；
两个 Worker 均为 0 sandbox/VM/CNI/shim/mount/active lease，集群 3/3 Ready。

## 未完成

S5.3a 尚需部署 `8dc39f77`/`a2626846` 并完成拆分前定向回归；S5.4a 尚未冻结 worker IPC、
启动 gate、Host scope owner、crash/reconnect 表和一秒 SLO。S5.4b/c 的 worker 拆分与普通启动
优化、S5.3b/c 的支持面/最终 Node E2E、S6.1～S6.3 的快照讨论与实现、S5.4d 一秒终验均未
开始。完整顺序和逐项验收标准以开发计划的“S5.3/S5.4 剩余实现单元与执行顺序”为准。

当前 S5.3 尚未形成最终支持面通过率、环境清理证据和 reviewer 结论。full-4 中有 10 项为
memory EmptyDir 在 Guest 中呈现 FUSE mount identity 的已知兼容性缺口，按
`K8S-OQ-025` 记录；不影响内容、权限和清理，但会失败于标准 `tmpfs` 类型断言。其余失败
仍需完成定向回归与逐项归因；79 项因 suite timeout 未执行。

## 验证

S3.4d 最终验证：`inv-v86nregacb` 在 `10b7af56` 完成 identity replacement、service
163/163 与 all-targets；`inv-686nvg0va4`/`inv-886nvfg6v6` 将同一 Shim 部署到双 Worker；
`inv-686k7g02nv` 默认规格启动即 OOM 8/8 为 `OOMKilled/137`；
`inv-v86ksj0ndb` 完成 restart/两次 resize/受控长 exec；`inv-686ktxgext`、
`inv-886ku00590`、`inv-a86kufg720` 完成 Guest/Host 组合矩阵；
`inv-086ncr074p` 完成最终 lifecycle regression；`inv-a86ndt0pkt`/`inv-a86nds0c3q` 双
Worker exact zero；`inv-v86nea09kv` 为 3/3 Ready。完整证据见
[S3.4d 摘要](./evidence/s3.4/s3.4d-execution-summary.md)。

S5.3 已完成的关键验证：`1df1da09` 在 W1 的定向与全量回归通过；错误模式基线
`inv-686q27g8sp` 在 39 项中得到 33 通过、6 失败后主动终止，证明 containerd 缺省
handler 不会让 kubelet 计入 RuntimeClass overhead；`inv-b86t69gf00` 验证 Kubernetes
v1.36 原生 MutatingAdmissionPolicy 会在 `e2e-framework` namespace 注入 `cube` 且得到
256Mi overhead/节点选择器；`inv-386td0gr45` 的 7 项门禁为 6 通过、1 失败，标准
NodeConformance OOM、Downward API、privileged HostPath/subPath 均通过，唯一失败是不属于
NodeConformance 的 NodeAllocatable Host OOM 差异。`inv-b86w410u0n` 已证明官方测试能把
`/root/kubelet-config` 改为 30s、重启临时 unit，并恢复为 20s，结果 1/1 通过。
`inv-686tgvghci` 主动停止时为 32 通过、4 个实际失败和 1 个中断：两项已执行的 tmpfs
identity 差异、旧 kubelet 配置路径问题及 `PrivilegedPod` dummy netdev 缺口。新一轮前
`inv-b86w4kgh72` 的 Cube Sandbox/VM/shim/TAP/mount/active lease 全为 0。
`f9120d79` 将 x86 BM/PVM Guest 的 `CONFIG_DUMMY` 改为内建；`inv-b86w9i084p` 的 PVM
构建产物 SHA-256 为 `633bb982…`，`inv-v86wfwg2wn` 保留旧 kernel 后部署；官方
`PrivilegedPod` `inv-v86wga0nm0` 为 1/1 通过，`inv-986wi0gicj` 最终 exact-zero。

full-4 `inv-a86wisgb60` 运行满 21600 秒，最终 `Ran 398 of 1197 Specs`，结果为
357 Passed、41 Failed、799 Skipped，并生成 ginkgo.json SHA-256 `f641f3bb…` 与 junit.xml
SHA-256 `c0c48906…`。其中 SIGKILL、Pod sysctl 与多项 sidecar 退出码由 `6d9c021a` 修复；
CPU Manager 暴露 host cpuset `2` 超出双 vCPU Guest `0-1`，`8dc39f77` 增加 Pod 级稳定
host→Guest CPU/NUMA 映射。云构建 `inv-6876060ap8` 已通过 cpuset 4/4、service 164/164、
all-targets 和 release build，Shim SHA-256 为 `550d5f35…`；尚未部署到 W1。

热启动诊断 `inv-9887r90bir` 使用已缓存 busybox、单容器、无 probe 的 5 个串行 Cube Pod，
client create→Ready 为 6459～6491ms，平均 6474ms；kubelet 增量中 `RunPodSandbox` 平均
6024ms，`CreateContainer`/`StartContainer` 平均 12/36ms，镜像拉取为 0。CubeShim 内部
Guest 到 vsock ready 平均 1130ms，Cloud Hypervisor BootVm API 平均 18ms，Agent
CreateSandbox 平均 7ms。`inv-8887w0ggbr`/`inv-98880agrwj` 的进程追踪发现单 Pod 启动
触发 264 次同步 `systemctl show`，反复执行 Host cgroup/lifecycle 稳定性校验，是约 4.5 秒
未优化开销的主因；Cilium CNI 约 104ms，RuntimeResource 网络准备约 64ms。测量 namespace
已由 `inv-v88827gg63` 删除，`inv-b8882igpkh` 确认 CRI Pod/container 均为 0。

## 阻塞

无当前外部阻塞。S5.4a 有两个进入实现前的决定门：`K8S-OQ-031` 需要冻结 worker 的创建、
放置、控制、回收和 IPC；`K8S-OQ-032` 需要用户确认默认一秒口径。S6.1 的 `K8S-OQ-008`
必须与用户讨论 runtime template 与 PodSnapshot 的状态语义、卷和分发边界，未确认前不冻结
artifact 格式。`K8S-OQ-028` 已关闭。首轮完整 NodeConformance 已因 6 小时
suite timeout 结束；后续通过先跑已修复项与 runner 门禁、再跑支持面回归来避免重复耗时。
P1 已知限制为持续长 exec + 同容器 resize 仍可能使首次
Update/探针超时；kubelet 重试后 resize 收敛，资源可精确清理。该组合不属于首版支持面，
在 `K8S-OQ-022` 转 S5.4 整改。另有 12 Sandbox 创建即取消的瞬时 `FailedKillPod`，重试
后 exact-zero，按 `K8S-OQ-023` 转 S5.4。二者均不阻断基础 E2E。
当前缓存镜像 Pod 热启动约 6.5 秒，其中 Host cgroup/lifecycle 重复稳定性校验为主要开销，
按 `K8S-OQ-030` 转 S5.4 优化；它不阻断 S5.3 功能兼容性验收。

当前 W1 的临时测试状态必须成组恢复：默认 runtime 已是 runc；
`96-cubesandbox-e2e-nodeconformance.toml` 临时启用 Cube privileged 并把官方
`test-handler` 映射到 runc；kubelet 由等价的 `kubelet-e2e.service` 运行；集群中只对带
`e2e-framework` 标签 namespace 生效的 `cubesandbox-e2e-runtimeclass` mutation
policy/binding 正在启用；临时 auth carrier 和两项 ClusterRoleBinding 正在启用。control
和 W2 kubelet 仍停止、对应 Node 对象仍从 API 暂时移除，CVM 没有删除。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。
云端仅操作本 PoC 创建的资源；名称带“勿删”的 CVM/TKE 不得删除。现有证据、构建产物和
回滚副本不得覆盖，handoff 不记录凭证。

## 下一步

1. 等 W1 exact-zero 后部署 `8dc39f77` Shim 与 `a2626846` Agent，只做 SIGKILL、两类
   sysctl、CPU Manager/PodResources 和 restartable sidecar 定向回归，冻结拆分前基线。
2. 输出 S5.4a 设计：CubeShim fork/exec gated worker，Cubelet 持 RuntimeResource/Host scope
   lease，worker 承载 VMM/vCPU/virtiofs/Guest memory；补齐 IPC、FD handoff、crash/reconnect、
   feature-flag rollback 和逐段时间戳，并关闭 `K8S-OQ-031/032`。
3. 实现 S5.4b/c，先证明普通启动功能等价、worker 正确归入 Pod leaf、故障 exact-zero，再删除
   正常路径 `systemctl show` 并完成普通 boot 50 次串行/10 并发分段测量。
4. 在 worker 路径执行 S5.3b 分片 NodeConformance，关闭支持面缺口并逐项登记不可通过原因；
   不把 host namespace、runner 或超时问题混为产品失败。
5. 与用户完成 S6.1 讨论后实现 RuntimeTemplate 和显式 PodSnapshot 启动；最后执行 S5.4d
   一秒门禁与 S5.3c 最终 Node E2E、清理和审计。
