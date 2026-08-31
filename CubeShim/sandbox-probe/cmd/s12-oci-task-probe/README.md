# S1.2 OCI Task 生命周期探针

该探针在隔离的 PoC 节点上验证 containerd 的标准 OCI image/snapshot/Task 路径。
它先用 Sandbox Controller 创建并启动一个 Cube VM，再通过 containerd 高层客户端把
两个普通容器加入同一 Sandbox：

- 自然退出 Task：`Create → Created → Wait(预注册) → Start → exit 23 → Stopped → Delete`；
- 强制终止 Task：`Create → Created → Wait(预注册) → Start → Running → SIGKILL → exit 137 → Delete`。

两个容器都使用 `overlayfs` 的标准 OCI snapshot 和 `io.containerd.cube.rs` runtime。
探针还断言 Task Create 后存在 host rootfs export mount，Task Delete 后 mount 消失，
但 Sandbox 的 RuntimeResource shared root 仍保留；最后才 Stop/Wait/Shutdown Sandbox。

构建：

```bash
cd CubeShim/sandbox-probe
go build -o /tmp/s12-oci-task-probe ./cmd/s12-oci-task-probe
```

运行：

```bash
/tmp/s12-oci-task-probe \
  /run/cubesandbox-s12/containerd.sock \
  /run/cubesandbox-s12/containerd-state \
  /proc/ANCHOR_PID/ns/net \
  s12-live-sandbox \
  mirror.ccs.tencentyun.com/library/busybox:1.36.1
```

IMAGE_REF 必须已导入探针 namespace `s12-live`，并已为 `overlayfs` 解包。成功时输出
`S12_OCI_TASK_OK`。节点验收脚本仍须独立检查 container metadata、snapshot、mount、
shim、VM、TAP、tc filter、RuntimeResource lease/shared root 均无残留。
