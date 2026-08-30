# CubeShim Sandbox API S0 探针

本目录是显式启用的 containerd 2.3 架构探针，不是生产 Cube runtime。二进制复用
containerd 的 runc Task Service，并增加最小 Sandbox Service 和 JSONL RPC trace，
用于在移植到 Rust CubeShim 前独立验证：

- bootstrap v3；
- `sandboxer = "shim"`；
- CRI、CNI、Sandbox 和 Task v3 的真实调用顺序；
- 同一 Sandbox endpoint 上的 Task 复用；
- 正常删除、创建失败、启动失败、创建取消和 shim 崩溃清理。

## 构建与配置

需要 containerd 2.3.4、runc、CNI reference plugins 和 crictl 1.36。显式构建：

```bash
go build -o containerd-shim-cube-s0-v1 .
install -m 0755 containerd-shim-cube-s0-v1 /usr/local/bin/
```

参考配置不会替换节点主 containerd，而是使用独立 root、state 和 socket：

```bash
install -d /etc/cni/net.d-cube-s0 /run/cube-s0 /run/cube-s0-containerd
install -m 0755 scripts/cube-s0-trace /opt/cni/bin/
install -m 0644 config/10-cube-s0.conflist /etc/cni/net.d-cube-s0/
install -m 0644 config/containerd.toml /etc/containerd/cube-s0.toml
containerd --config /etc/containerd/cube-s0.toml
```

用 `config/crictl.yaml` 连接独立 CRI endpoint，并在 `runp` 时选择 handler：

```bash
crictl --config config/crictl.yaml runp --runtime cube-s0 pod.json
```

仓库中的固定输入和云端验收脚本可重放完整正常/异常矩阵：

```bash
sudo scripts/verify-cloud.sh
```

脚本使用 `testdata/pod.json`、`testdata/container.json`，断言 Sandbox Ready、
业务进程 exit code 23、日志、bootstrap v3/ttrpc、Sandbox/Task 同 endpoint PID 与
关键 RPC 顺序。每例结束后检查 CRI Pod/Container、containerd sandbox metadata、
shim 进程/socket、state/root bundle、mount、netns、host-local IP 分配均为零，并确认
CNI ADD/DEL 实际执行成功。原始 RPC/CNI trace、失败输出和摘要写入
`ARTIFACT_DIR`。

shim 默认写 `/run/cube-s0/trace.jsonl`，CNI wrapper 写
`/run/cube-s0/cni.jsonl`；可用 `CUBE_S0_TRACE_PATH` 改写 shim trace 位置。

## 调用与清理责任

实测正常顺序为：

1. CRI 创建 netns，执行 CNI ADD；
2. shim bootstrap v3 返回 Task v3 endpoint；
3. Sandbox `CreateSandbox → StartSandbox → WaitSandbox`；
4. 创建业务容器时查询 `SandboxStatus/Platform`；
5. 同一 endpoint 执行 Task `Create → Start → Wait`；
6. 删除时先 Task `Kill/Delete`，再 Sandbox `StopSandbox`；
7. CRI 执行 CNI DEL 和 netns 删除；
8. `ShutdownSandbox` 后 containerd 执行 shim delete 和 bundle 清理。

清理责任：CNI ADD 失败或 Sandbox 创建前失败由 CRI 回滚 netns；Sandbox
`Create/Start` 失败由 shim controller 调用 `ShutdownSandbox`、删除 shim/bundle；
Task 创建失败由 CRI 删除 Task/snapshot；正常或强制删除由 CRI 先清 Task，再 Stop
Sandbox、CNI DEL、Shutdown。CNI DEL 与各删除 RPC必须幂等。

## S0 failpoint

以下 sentinel 只用于云端清理测试，正常路径中不存在：

- `/run/cube-s0/fail-create`：CreateSandbox 返回错误；
- `/run/cube-s0/fail-start`：StartSandbox 返回错误；
- `/run/cube-s0/crash-create`：CreateSandbox 中模拟 shim 崩溃；
- `/run/cube-s0/delay-create`：CreateSandbox 延迟 10 秒，用于取消请求。

每个用例结束后至少检查 CRI Pod/Container、containerd sandbox metadata、shim
进程和 mount 均为 0。

## 演进

S1.1 要把本探针已经验证的 bootstrap、双服务注册、状态枚举、endpoint 和清理契约
移植到 Rust CubeShim，并把 runc Task 替换为 Cube-backed Task。替换完成后删除本
Go 探针，保留配置和 E2E 用例作为回归测试。
