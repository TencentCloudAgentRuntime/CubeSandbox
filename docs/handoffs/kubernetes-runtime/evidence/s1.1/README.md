# S1.1 Sandbox VM 生命周期验收证据

> 状态：`VALIDATING`。本地协议、状态机、FD handoff 与失败回滚已通过；真实 PVM/KVM Cube VM 的云端成功链路尚待源码同步门禁解除。

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

## 本地回归

```bash
cd Cubelet
go test -race ./services/runtime/... ./plugins/cube/runtime_resource
go vet ./services/runtime/... ./plugins/cube/runtime_resource
```

结果：RuntimeResource service、handoff、state 和 plugin 全部通过，race 0、vet 0。

```bash
cd CubeShim
LIBRARY_PATH=/tmp/cubesandbox-link-libs cargo test -p containerd-shim-cube-rs --lib
cargo check -p containerd-shim-cube-rs
```

结果：`96 passed; 0 failed`，`cargo check` 通过。依赖仓库原有 generated code 警告仍存在，没有新增编译错误。

## 云端状态

- 目标：香港二区我们创建的 `ins-4dyul5ag`（名称含“勿删”），16C32G，Linux 6.6 PVM host，`/dev/kvm` 可用，containerd 2.3.4。
- 只读基线 TAT：`inv-b82na40m3i` 成功；确认 `/opt/cubesandbox-src` 仅含早期 S0.3 overlay，不含 RuntimeResource/S1.1 源码。
- 待执行：把当前分支相对公开基线的 245KB Git bundle（SHA-256 `fe2b693329a59daf7e4214b704d3afef66ed6a0aaac0c99a6d2568384563ed97`）同步到该 CVM，构建当前 CubeShim/Cubelet，并完成真实 Create→Start→Status→Stop→Shutdown 与异常回滚。
- 阻塞：执行策略要求用户在聊天中明确批准具体源码 payload 和目的地；未获批准前不通过公开 push、其他 bucket 或间接命令绕过。

S1.1 在真实 VM 成功链路、清理检查和 subagent `APPROVE` 前不得标记 `DONE`。
