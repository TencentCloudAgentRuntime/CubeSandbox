# S1.1 完整生命周期探针

该探针只用于隔离的云端 PoC 节点。它通过 containerd 2.x 的公开 Sandbox
Controller gRPC，驱动一个 Cube sandbox 完成：

`Create → Status(Created) → Platform → Start → Status(Ready) → Stop → Status(Stopped) → Wait → Shutdown`

构建：

```bash
cd CubeShim/sandbox-probe
go build -o /tmp/s11-lifecycle-probe ./cmd/s11-lifecycle-probe
```

运行：

```bash
/tmp/s11-lifecycle-probe \
  /run/cubesandbox-s11/containerd.sock \
  /run/cubesandbox-s11/containerd-state \
  /proc/ANCHOR_PID/ns/net \
  s11-live-sandbox
```

`NETNS_PATH` 必须来自同节点、已完成 CNI ADD 的非 hostNetwork Pod。探针断言
RuntimeResource lease/generation 在 Start 前后不变、Stop 后消失、Wait 为退出码 0，
同时确认 Create 后 shim bundle/cleanup record 确实存在、Stop 后 cleanup record
消失、Shutdown 后同一个 bundle 消失。成功输出 `S11_CUBE_LIFECYCLE_OK`。

节点验收脚本仍须在探针退出后独立检查 production adapter record、shared root、
TAP、tc filter、VM 进程和 RuntimeResource lease store 均无残留；探针的 Status
断言不能代替这些 host artifact 检查。
