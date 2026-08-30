# S0.3 CNI 网络探针

该探针验证 CNI 已创建 Pod netns 之后，Cube VM 是否能复用同一个 Pod IP、MAC、
route、DNS 和 Cilium identity。数据面采用 Kata Containers 社区默认的
`tcfilter` 模型：在 Pod netns 内创建 TAP，在 CNI `eth0` 与 TAP ingress 上安装双向
`mirred redirect`，然后由 feature-gated CubeShim adapter 打开 TAP FD 并交给内置
hypervisor。VMM 不需要常驻 Pod netns。TAP 的 vnet header 与 fd offload 在源 netns
内完成配置；跨 netns 交给 VMM 后不再执行依赖当前 netns 的 ioctl，并仅向 Guest 暴露
不依赖 TAP offload 的 virtio-net features。因此 S0.3 验证的是网络语义而非卸载性能。

`io.containerd.cube.s0.cni-netns=<absolute path>` 只用于 S0 探针。S1 必须从标准
SandboxService `netns_path` 获取路径，并把 TAP/tc 生命周期移入 Cubelet network
adapter；CRI/Pod 不应生成此 annotation。

PoC 安全权衡：内嵌 VMM 的 `Thread::All` seccomp 会同时约束 shim，而 shim 仍负责
containerd OCI rootfs bind 的回滚与删除，因此 runtime allowlist 临时增加 `umount2`。
父目录清理由原有允许的 `unlinkat(AT_REMOVEDIR)` 完成，不再扩大 syscall；S1 应把
mount 生命周期隔离到专用适配层并重新收窄 allowlist。

云端基线是 Kubernetes 1.36.4、containerd 2.3.4、Cilium 1.20.0、Linux 6.6+ PVM。
`cloud/` 脚本准备两节点自建集群，`manifests.yaml` 固定 source/peer endpoint、
Service 和最小 egress NetworkPolicy。`run.sh` 必须在 source 节点以 root 运行；
它复用 CNI source Pod 的 netns，启动一个标准 OCI BusyBox rootfs 的 Cube VM，验证：

source Pod 中的 runc 容器仅用于在 S0 保持标准 CNI endpoint/netns 存活，不承载业务；
因此这是网络契约探针，不是最终 Pod 生命周期模型。S1 由 Cube Sandbox 自身持有该
netns，移除这个 anchor 容器。

- Kubernetes Pod IP 与 Guest `eth0` 相同；
- 集群 DNS 和 Service ClusterIP；
- 到另一节点 peer Pod 的直连；
- Cilium egress NetworkPolicy 拒绝 denied Pod；
- 非法 netns 创建失败后，rootfs mount/share、Task、Container 和 Shim 均为 0；
- 正常删除后，Task/Container/Shim、TAP、tc filter 和 Kubernetes namespace 均清理；
- 探针按专用 namespace 和 task ID 回收创建失败产生的孤儿 shim，重复执行不会复用失效 socket。

探针不会替换节点主 containerd：Cube Task 使用独立
`/run/containerd-cube-s0.3/containerd.sock`，Kubernetes/Cilium 使用系统
containerd。
