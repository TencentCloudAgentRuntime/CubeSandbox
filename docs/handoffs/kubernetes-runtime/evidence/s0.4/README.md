# S0.4 组件接口验收证据

## 当前结论

S0.4 v1 契约已按两轮独立审查整改，当前等待第三轮复审。宿主 containerd 独占 CRI、OCI image/snapshot、Sandbox/Task 与 CNI 状态；Cubelet RuntimeResource 仅准备和释放节点资源；Guest Agent 只负责 VM 内容器执行。不得在复审 `APPROVE` 前把 S0.4 标为 `DONE`。

## 产物

| 产物 | 提交 |
|---|---|
| RuntimeResource v1 proto、生成代码、descriptor 测试与 API 文档 | `40f4389a`，FD lease 扩展 `ea192ecb` |
| Agent capability negotiation 与 CubeShim 缓存/兼容解析 | `30bf3365` |
| 初版调用图与契约探针 | `eb7aed1a`、`2e2612a4` |
| 持久化 lease/tombstone 状态机、FD handoff v1、direct gRPC registration 与真实 import-graph 测试 | `ea192ecb`；Release 协调器与强制 peer auth `e3205220` |

接口定义包含 `GetCapabilities`、`PrepareSandbox`、`ReleaseSandbox`、`InspectSandbox` 和只报告的 `ReconcileSandboxes`。TAP FD 不进入 protobuf；Kubernetes 专用 Unix 协议通过 `sandbox_id + generation + lease_id + network_handle + token` 精确匹配当前 READY lease 后，才使用 `SCM_RIGHTS` 发送 fresh duplicate。legacy cubetap JSON 协议未修改。

## 首轮独立审查与整改

首轮结果为 `CHANGES_REQUIRED`，提出三项问题：FD 交付缺少 generation/lease 栅栏；Prepare/Release 的持久化重试、tombstone 与精确 gRPC 结果不完整；递归 containerd 防线只有文本 grep，证据表述过强。

`ea192ecb` 完成以下整改：

- FD 请求冻结五个 lease 身份字段和 versioned frame；Registry 内校验与 duplicate 同一临界区；错误响应强制 0 FD，成功恰好 1 FD；明确 retry ownership、deadline 与 `SO_PEERCRED`。
- 文件持久化状态机先 fsync/rename 记录 PREPARING/READY/RELEASING、high watermark、idempotency key 和 tombstone；精确规定同 key、不同 key、跨 generation/operation、错误 lease、重启恢复和旧操作重放结果。
- RuntimeResource 直接注册到 `grpc.ServiceRegistrar`；单测执行 `go list -deps ./services/runtime/...`，实际禁止 containerd 和 legacy Cubelet service 依赖。
- 测试覆盖 Registry replacement、stale/released lease、重试 fresh FD、非法/部分 frame、错误无 FD，以及状态机 restart/tombstone/key/lease 组合。

## 第二轮独立审查与整改

第二轮结果仍为 `CHANGES_REQUIRED`：`Store.BeginRelease` 与 `Registry.Invalidate` 分属两个锁，存在已持久化 RELEASING 但仍可 Acquire 的窗口；`ServeConn` 的 nil authorizer 可绕过 peer credential。

`e3205220` 增加 `Coordinator`，固定 Coordinator → Registry → Store 锁序：进行中的 duplicate 先完成，Release 在 Registry 锁内持久化并在解锁前删除 binding；持久化失败保留 READY，重启仅发布 READY，replacement 复用同一路径。`ServeConn` 缺少 authorizer 时 fail closed，并以真实 `SO_PEERCRED` 验证 allow/deny，拒绝路径不调用 TAP opener 且携带 0 FD。组合测试及 20 轮 race 重放均通过。

精确状态迁移、gRPC code、FD ownership 和失败顺序见 [S0.4 接口边界](../../../../zh/dev/kubernetes-runtime-integration-s0.4-interface.md)。

## 验证

| 验证 | 结果 |
|---|---|
| `cd Cubelet && go test ./api/services/runtime/v1 ./services/runtime/...` | 通过 |
| `cd Cubelet && go test -race ./services/runtime/...` | 通过 |
| `cd Cubelet && go test -race ./services/runtime ./services/runtime/handoff -run 'Coordinator|ServeConn|RegistryAcquire|PublishConflict' -count=20` | 通过 |
| `cd Cubelet && go vet ./services/runtime/...` | 通过 |
| `./tests/s0-interface-contract/run.sh` | 官方 builder 内输出 `S0_4_INTERFACE_CONTRACT_OK`；Go 全部 runtime contract、Health proto 一致性、Shim/Agent 定向测试和格式检查通过 |
| 前一轮 `make shim-test` | CubeShim 76 项、cube-runtime 1 项通过，0 失败；本次未修改 Rust 实现 |
| 前一轮 builder 内 `cargo test --manifest-path agent/Cargo.toml -p cube-agent` | 114 项通过，0 失败；本次未修改 Agent 实现 |
| `git diff --check` | 通过 |
| 云节点环境检查 | TAT `inv-882hf6088t`、`inv-v82hib0njt`：本 PoC control 节点在线并保留 builder image |

平台在执行前拒绝了本地分支归档上传，因此 S0.4 未在云节点重放，云端也未产生该归档或源码变更。S0.4 是 protobuf、状态机、依赖边界和编译期 capability 契约，不使用 KVM/CNI 数据面；S1 的真实 Sandbox/VM 生命周期仍必须在本 PoC 云节点验收。

## 审查门禁

同一独立 subagent 必须复查 `ea192ecb`、`e3205220`、本证据、接口文档与测试，并明确返回 `APPROVE`；否则继续整改和复审，不进入 S1。
