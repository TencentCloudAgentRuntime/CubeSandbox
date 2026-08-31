# S1.1 dead-shim 清理探针

该命令向真实 containerd 2.3 Sandbox Controller 发送 `Create` 请求，等待
CubeShim 持久化 `cube-runtime-resource.json`，只终止本次创建的 shim，并验证
containerd 的 dead-shim `delete` 动作：

- 把精确的 generation 与 lease 移交给独立 reaper；
- Cubelet 恢复后完成 Release；
- 删除清理记录、reaper job 与 containerd sandbox bundle。

在 `sandbox-probe` 模块中构建：

```bash
go build -o /tmp/s11-crash-probe ./cmd/s11-crash-probe
```

针对隔离 containerd 和 RuntimeResource 验证服务运行。Release 标记内容必须为
`released SANDBOX_ID GENERATION LEASE_ID`：

```bash
/tmp/s11-crash-probe CONTAINERD_SOCKET CONTAINERD_STATE RELEASE_MARKER SANDBOX_ID
```

普通路径成功时输出 `S11_SHIM_KILL_RELEASE_OK`。

要注入 Cubelet 临时不可用故障，设置两个控制文件：

```bash
S11_CRASH_READY_FILE=/tmp/s11/ready \
S11_CRASH_CONTINUE_FILE=/tmp/s11/continue \
  /tmp/s11-crash-probe \
  CONTAINERD_SOCKET CONTAINERD_STATE RELEASE_MARKER SANDBOX_ID
```

探针写入 `S11_CRASH_READY_FILE` 后暂停。此时停止 RuntimeResource 服务，创建
`S11_CRASH_CONTINUE_FILE`，等 shim 被终止且 reaper job 已写入后，再用同一状态
目录重启 RuntimeResource 服务。成功时输出
`S11_SHIM_KILL_RETRY_RELEASE_OK`。

隔离 containerd 应设置绝对路径
`CUBE_RUNTIME_RESOURCE_REAPER_DIR`；未设置时 CubeShim 使用
`/run/cubesandbox/runtime-resource-reaper`。该探针仅为按需运行的 PoC 工具，
不会进入 CubeShim 运行时进程。
