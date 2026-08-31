# S1.1 Sandbox VM 生命周期验收证据

> 状态：`VALIDATING`。本地协议、状态机、FD handoff、乱序 cleanup、dead-shim job-only 恢复和 production 云测入口已通过代码复审；真实 PVM/KVM Cube VM 的云端成功链路尚待离线依赖传输门禁解除。

## 实现范围

- CubeShim 使用 containerd 2.3 bootstrap v3，在同一 ttrpc endpoint 注册官方 Sandbox 与 Task Service。
- Sandbox `Create/Start/Stop/Shutdown/Wait/Status/Platform` 具有显式 phase、幂等重试和 detached operation；一个 Sandbox 只持有一个 Cube VM 与一个 RuntimeResource lease。
- CubeShim 解码真实 CRI v1 `PodSandboxConfig`，合并 Pod/request annotations、DNS 和聚合 CPU/内存；Sandbox bundle 不依赖 pause 容器 `config.json`。
- Cubelet RuntimeResource 提供持久化 Prepare/Release/Inspect/Recover、Cilium tcfilter attachment 和带 generation/lease/network/token 栅栏的真实 `SCM_RIGHTS` TAP listener。
- Start 前检查 Guest assets/shared root 与 `/dev/kvm`；任何 preflight、FD 或 VM 启动错误均先回滚 VM，再精确 Release lease。

实现提交：

- `871e9f7a`：采用 containerd 2.3 官方 Sandbox bindings。
- `47522929`：实现 Sandbox VM 生命周期、RuntimeResource adapter/recovery 与测试。
- `e7881524`：修正真实联调发现的 route family、asset/KVM preflight、API version negotiation 和 durable state 枚举覆盖。
- `dfdc0455`：串行化 Shutdown 与 detached Create/Start/Stop，并在 VM teardown 错误时清除已释放 lease。
- `f61d1317`：抽取可测试的 Shutdown transition，并增加并发操作等待与重复关闭回归测试。
- `8713d4dd`、`aff6b0d5`、`e6a15a8b`：加固 recovery，预写确定性 cleanup identity，并增加 bundle 外 detached reaper 与 dead-shim 探针。
- `a1b6173f`：关闭取消上下文、READY commit-unknown、FD control truncation、multi-queue TAP 和长时重试被 containerd kill 的恢复缺口。
- `80c3050a`：实现 Release-before-Prepare durable fence、Go/Rust 共享身份向量、持久 reaper queue fsync 与 Cubelet startup/continuous scanner。
- `37e08b32`：确保 exact active/tombstone Release 重试成功前重新 fsync 父目录，覆盖重启后 post-rename response-loss。
- `76c7f760`：增加使用 production Linux adapter 的独立 RuntimeResource 云测服务，以及覆盖 Create→Start→Status→Platform→Stop→Wait→Shutdown 的 containerd Controller 探针；探针验证真实 bundle/cleanup record 的存在与消失，并处理 Create 响应丢失和同 ID 并发 ownership。

## 官方 containerd wire 验证

使用官方 containerd `v2.3.4` 的 Go API client 和 daemon，采用隔离的 root/state/socket；runtime name 为 `io.containerd.cube.rs`，shim 二进制为本分支 debug build。

第一步在 RuntimeResource endpoint 故意不存在时发送真实 `Controller.Create`：请求不提供 OCI `config.json`，`Any` 内为 CRI v1 `PodSandboxConfig`。返回错误准确到 `prepare RuntimeResource: connect RuntimeResource`，证明 containerd bootstrap、Sandbox ttrpc 注册和 CRI options 解码均已越过，标记为 `S11_CONTAINERD_CRI_OPTIONS_WIRE_OK`。

第二步启动真实 Cubelet RuntimeResource gRPC + Unix FD listener，返回真实 TAP FD；本机故意没有 `/dev/kvm`。结果：

```text
S11_CROSS_CREATE_OK
rpc error: code = FailedPrecondition desc = failed to start sandbox "s11-cross-sandbox-v5": failed to start sandbox s11-cross-sandbox-v5: acquire RuntimeResource TAP: open KVM device /dev/kvm: No such file or directory (os error 2)
S11_CROSS_START_REACHED_VMM
```

Cubelet 随后记录精确释放：

```text
released s11-cross-sandbox-v5 3 18cc0e1ed5c6e800ae99d56b81ebfb3cc08c1acca1847ec023f8e7643e3d3413
```

对应 durable record 的 generation 3 已转为 tombstone，无 active lease；`containerd-shim-cube-rs` 进程和本次 sandbox socket 均为 0。联调同时发现并修复 legacy Cube 网络 JSON 缺少必填 route `family` 的问题；IPv4/IPv6 family 和非法 IP 均已有单测。

## 隔离 containerd job-only 恢复

使用 containerd 2.3.4 的独立 root/state/socket 和当前二进制：

1. 创建 Sandbox 并停止 RuntimeResource harness；
2. 终止本次 shim，让 dead-shim delete helper 写入 bundle 外 durable reaper job；
3. 精确终止本次 detached `runtime-resource-reaper`，确认 Release marker 不存在、job record 仍在；
4. 不重启 containerd，仅用相同 state/reaper 目录重启 harness。

Cubelet startup scanner 独立完成精确 Release，探针输出：

```text
S11_SHIM_KILL_RETRY_RELEASE_OK
```

随后 reaper job、adapter record、containerd sandbox bundle 均为空，containerd PID 保持不变。Release-before-Prepare、并发乱序、首次 parent-fsync 失败后的重启重试也有 Go race 回归；同一 subagent 独立重跑并对实现 `APPROVE`。

## 本地回归

```bash
cd Cubelet
go test -race ./services/runtime/... ./plugins/cube/runtime_resource/...
go vet ./services/runtime/... ./plugins/cube/runtime_resource/...
```

结果：RuntimeResource service、handoff、state、plugin 和 production 云测服务全部通过，race 0、vet 0；服务层禁止依赖 containerd/legacy service 的 import graph 防线仍通过。

```bash
cd CubeShim
LIBRARY_PATH=/tmp/cubesandbox-link-libs cargo test -p containerd-shim-cube-rs --lib
cargo check -p containerd-shim-cube-rs --all-targets
```

```bash
cd CubeShim/sandbox-probe
go test -race ./...
go vet ./...
```

结果：`105 passed; 0 failed`，`cargo fmt --all --check` 与 `cargo check -p containerd-shim-cube-rs --all-targets` 通过。Cubelet RuntimeResource/plugin 与 sandbox-probe 的 Go race/vet 均通过；依赖仓库原有 generated code 警告仍存在，没有新增编译错误。

## 云端状态

- 运行目标：香港二区我们创建的 `ins-4dyul5ag`（名称含“勿删”），16C32G，Linux 6.6 PVM host，`/dev/kvm` 可用，containerd 2.3.4；构建节点为我们创建的 `ins-pl7mznaa`（名称含“勿删”）。
- 只读基线 TAT：`inv-b82na40m3i` 成功；确认 `/opt/cubesandbox-src` 仅含早期 S0.3 overlay，不含 RuntimeResource/S1.1 源码。
- 源码同步：用户已批准 207627-byte gzip binary patch（SHA-256 `532ddfcb57d22c77a5f50c8b9ae74621f90fd906359a89611976a3e82dd503c5`）上传到私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；`inv-082uv90m3d` 在运行节点、`inv-a82vki0tnp` 在构建节点成功展开到提交 `37e08b32` 对应 tree `404ecb2d1a0fab21c1edcb6c74c8145c86950658`。
- 云端依赖预检：Rust 1.97.1/1.89 镜像版本正确，但严格 offline 分别缺少 `anyhow`、`async-trait`；Tencent Go proxy 返回的 containerd v2.2.2 模块校验和与仓库 `go.sum` 不一致，因此不得作为构建来源或验收证据。
- 待授权 payload 1：从云端现有 `37e08b32` 到实现 `76c7f760` 的 10385-byte gzip binary patch，SHA-256 `546ecb63fbf5f97a062ef5b5e526ff0b5a7d48df1f50b2bcc4f5de1f1764c90f`；本地临时 clone 重放后 tree 为 `6b152141e2346c5446d344bec26a6465d4353401`，与目标完全一致。
- 待授权 payload 2：84415811-byte 离线 vendor 包，SHA-256 `68c419e6c89e6e6751620952a67c2c55352a859f31696588492f8f2b659935d9`，仅含 `cargo/`、`go-cubelet/`、`go-sandbox-probe/`；已审计为普通文件、无 symlink/special/unsafe path/凭证命中。
- 阻塞：执行策略要求用户明确批准上述两个新 payload 上传到同一私有 COS 并下载到我们创建的 CVM；未获批准前不上传或通过其他传输方式绕过。

代码 reviewer 已对 `76c7f760` 的云测入口在第五轮复审明确 `APPROVE`。S1.1 在真实 VM 成功链路、宿主残留/异常回滚检查和云端结果最终复审 `APPROVE` 前不得标记 `DONE`。
