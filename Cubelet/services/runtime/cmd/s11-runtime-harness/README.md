# S1.1 RuntimeResource 持久化验证服务

该命令只用于 PoC 验证。它启动真实的 RuntimeResource gRPC 与 FD handoff
服务，并把 sandbox 状态、适配器状态和 Release 标记持久化到指定目录，从而
可以在进程重启前后验证精确租约清理。

构建：

```bash
go build -o /tmp/s11-runtime-harness ./services/runtime/cmd/s11-runtime-harness
```

运行：

```bash
/tmp/s11-runtime-harness \
  STATE_DIR GRPC_SOCKET FD_SOCKET RELEASE_MARKER ASSET_DIR [REAPER_DIR]
```

`ASSET_DIR` 必须包含 `kernel`、`agent` 和 `guest.img`。服务就绪时输出
`S11_RUNTIME_HARNESS_READY`；成功 Release 后，标记文件内容为
`released SANDBOX_ID GENERATION LEASE_ID`。重启时必须复用相同的
`STATE_DIR`，其余路径也应保持不变。`REAPER_DIR` 省略时使用 `STATE_DIR/reaper`；
故障注入时应显式传入与 CubeShim `CUBE_RUNTIME_RESOURCE_REAPER_DIR` 相同的目录。
