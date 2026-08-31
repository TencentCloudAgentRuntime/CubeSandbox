# S1.1 Sandbox VM 生命周期验收证据

> 状态：`DONE`。本地可靠性闭环和真实 PVM/KVM Cube VM 云端终验均已通过，同一 reviewer 最终复审 `APPROVE`。

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
- `76c7f760`：增加使用 production Linux adapter 的独立 RuntimeResource 云测服务，以及覆盖 Create→Created Status→Platform→Start→Ready Status→Stop→Stopped Status→Wait→Shutdown 的 containerd Controller 探针；探针验证真实 bundle/cleanup record 的存在与消失，并处理 Create 响应丢失和同 ID 并发 ownership。
- `7b79ba97`：在 tc redirect 生效前解析 Cilium 网关邻居，并修正多 TAP queue 删除时过早返回。
- `d7ab89f7`：优先调用 containerd public Platform；仅在返回 `Unimplemented` 时校验 bootstrap v3/ttrpc/绝对 Unix socket 并直连 CubeShim Platform。
- `f2708859`：接受 Cilium 已创建的网关直连 host route，避免重复添加返回 `EEXIST`。
- `22716267`：Stop 已完成 VMM destroy/join 后，Shutdown 只做防御性 Release、最终状态和退出通知，不再向关闭的 VMM channel 二次发送 abort；直接 Shutdown 仍执行 force abort。

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

## 云端严格构建与终验

- 目标：香港二区我们创建的运行节点 `ins-4dyul5ag` 和构建节点 `ins-pl7mznaa`（名称均含“勿删”）；16C32G、Linux 6.6 PVM host、`/dev/kvm` 可用、containerd 2.3.4。
- 源码：两台 CVM 的最终云测投影 tree 均为 `6e3b76eb94f378d5a8c2b02368c2dd28f6f2d90b`；Shutdown 文件 blob `fc0edf2e3d84c5b8b4230fd61c9c00dca3d94dc0`。同步验证 `inv-8831v50a2j`、`inv-9831v30ak5` 均为 `SUCCESS`。
- CubeShim：固定 Rust 1.97.1、offline、locked 构建执行 lib 单测、all-targets check 和 release build，TAT `inv-b831vp0wan` 为 `SUCCESS`；`containerd-shim-cube-rs` SHA-256 `805658814730f6440b1ee8d281c8e84ef7f07f5543378d844feb78df984812ff`，`cube-runtime` SHA-256 `d685f5ea004be79348b7ef8224b697247c2ed956b19b1d5d668092c2a229a2e0`。
- Go 云测产物：严格构建 `inv-b831k5g4a8` 为 `SUCCESS`；runtime harness SHA-256 `58fdc92b0fb6f60e8535eb08e7f27c06e2ac1b1358dbb9ac3f3ddd2360a071e2`，lifecycle probe SHA-256 `144b0f3cd8b938520b16fb685a26ab5630d92ce5bde2326f3270889abf5a6f67`。
- Agent：静态二进制 SHA-256 `d5f53e7f253eb26aa62c52ea000ce5bdba7feeb788101de6f484a4b7cb63a243`，验收 ext4 SHA-256 `6d4efcd1ef0285696cfd66eb91637e532fc3e89d55a3db02019b2ba0be8d320f`。该资产用 `seccomp=no` 构建，仅证明 S1.1 生命周期，不宣称 S3 seccomp 支持。

终验 TAT `inv-38324c05ra` 在 `ins-4dyul5ag` 为 `SUCCESS`，证据目录 `/data/cubelet/s1.1-evidence/20260831T053104Z`。关键结果：

```text
S11_CUBE_LIFECYCLE_OK sandbox=s11-live-sandbox ... generation=1
S11_PLATFORM_DIRECT_TTRPC_FALLBACK sandbox=s11-live-sandbox
S11_HOST_RESIDUE_CLEAN adapter=0 shared=0 reaper=0 cleanup_records=0 taps=0 filters=0 active_leases=0
S11_EXPECTED_ROLLBACK_OK sandbox=s11-fail-sandbox rc=2
S11_LIVE_ACCEPTANCE_OK tree=6e3b76eb94f378d5a8c2b02368c2dd28f6f2d90b pod_ip=10.244.2.113 lease_records=2
S11_STATIC_ANCHOR_CLEAN
```

成功链路真实执行 Create→Created Status→Platform→Start→Ready Status→Stop→Stopped Status→Wait→Shutdown。失败链路使用缺少 `eth0` 的 netns，在 Controller Create 的 RuntimeResource Prepare 阶段失败；回滚后 adapter/shared/reaper/cleanup record、sandbox metadata、shim、TAP、tc filter、mount 和 active lease 全部回到零，同时保留 2 条 durable tombstone lease record；Cilium anchor 最终删除。

代码 reviewer 已分别对 Platform fallback、Cilium route 修复和 Stop→Shutdown 幂等修复给出 `APPROVE`，并对最终证据、生命周期顺序、失败阶段、active lease 清理与 durable tombstone 结论完成复核，明确 `APPROVE` S1.1 `DONE`。
