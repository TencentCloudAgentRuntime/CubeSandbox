# S1.1 生产 RuntimeResource 云测服务

该命令只用于隔离的 Linux 云节点。它不启动完整 Cubelet，但装配与 Cubelet
插件相同的生产 `RuntimeResource` adapter：读取 Create 请求中的 Pod netns，
建立 tc redirect 和 multi-queue TAP，并通过 FD handoff 把真实 TAP 交给 CubeShim。

```bash
cd Cubelet
go build -o /tmp/s11-live-runtime-harness \
  ./plugins/cube/runtime_resource/cmd/s11-live-runtime-harness

/tmp/s11-live-runtime-harness \
  /data/cubelet/s11-live/state \
  /run/cubesandbox-s11/runtime-resource.sock \
  /run/cubesandbox-s11/runtime-resource-fd.sock \
  /data/cubelet/s11-live/assets \
  /data/cubelet/s11-live/reaper
```

`ASSET_DIR` 必须包含 `kernel`、`agent` 和 `guest.img`。shared root 默认是
`/data/cubelet/s11-runtime-harness/shared`；可以通过
`S11_RUNTIME_HARNESS_SHARED_ROOT` 覆盖，但命令会拒绝 `/data/cubelet` 之外或
等于 `/data/cubelet` 的路径。服务就绪时输出 `S11_LIVE_RUNTIME_HARNESS_READY`。
