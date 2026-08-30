# S0.2 RootFS/virtiofs 探针

该探针验证 containerd 标准 `CreateTaskRequest.rootfs` 能进入真实 Cube Guest。它只在
OCI spec 明确设置 `io.containerd.cube.s0.standard-rootfs=true` 时启用，不改变
legacy Cube 链路；S1 应把这段转换演进到 Kubernetes Sandbox 生命周期后删除此开关。

## 设计结论

- containerd 继续负责 OCI image 与 overlayfs active snapshot。
- CubeShim 不把 Host merged overlay 直接作为 Guest overlay lower，因为
  overlay-on-virtiofs-on-overlay 在 Guest 6.6 返回 `EINVAL`。
- CubeShim 按 containerd 原顺序导出 active upper 与 image lower layers，在固定
  `/data/cubelet/s0.2-share/<sandbox>` 下建立 bind；Guest Agent 在这些 lower 之上建立
  自己的临时 writable overlay。
- virtiofs 使用 `cache=never`、`read_only=true`、`announce_submounts=false`。开启
  submount 通告会令 Guest overlay 对 layer lower 返回 `EINVAL`。
- 在线新增 bind、Host rename 和只读切换可被 Guest 立即看到。Guest lookup 后普通
  Host `umount` 可能因 virtiofsd inode 引用返回 `EBUSY`，应先解除 Guest 容器内消费，
  再用 `MNT_DETACH`，并使用不复用的 container/volume generation 路径；引用在 Task/VM
  删除时释放。S3 的 volume RPC 必须显式实现这个 Guest-first 顺序。
- Guest writable upper 当前是临时层，不回写 containerd active upper；这满足 S0/S1
  运行语义，持久化 writable layer 与 snapshotter 对账在 S3 决定。

## 重放

前置条件是 `/dev/kvm`、匹配的 PVM Host/Guest kernel、Cube Agent/Guest image、
containerd 2.3.x，以及已经拉取的 `busybox:1.36.1`。隔离配置见
`containerd.toml`，启动命令示例：

```bash
containerd --config CubeShim/s0-rootfs-probe/containerd.toml
```

构建并把 `containerd-shim-cube-rs` 放到 containerd 按
`io.containerd.cube.rs` 解析的 PATH 后执行：

```bash
sudo CubeShim/s0-rootfs-probe/run.sh
```

可用 `ADDRESS`、`NAMESPACE`、`CTR`、`IMAGE`、`KERNEL`、`AGENT`、`GUEST_IMAGE`、
`SHARE_BASE`、`SOURCE_BASE` 和 `CYCLES` 覆盖默认值。成功标志是
`S0_2_ROOTFS_PROBE_OK`；默认执行退出码 23、动态挂载矩阵和 20 次创建/删除，并要求
最终 mount、share、Task、Container、Shim 计数全部为 0。
