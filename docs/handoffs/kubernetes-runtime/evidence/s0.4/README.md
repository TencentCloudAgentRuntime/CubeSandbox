# S0.4 组件接口验收证据

## 结论

S0.4 已形成可编译、可测试的 v1 契约草案：宿主 containerd 独占 CRI、OCI image/snapshot、Sandbox/Task 与 CNI 状态；Cubelet RuntimeResource 仅准备和释放节点资源；Guest Agent 通过兼容扩展的 `Health.Version` 声明版本化能力。新 Kubernetes 链路无需、也不得递归进入 Cubelet 内嵌 containerd。

## 产物

| 产物 | 提交 |
|---|---|
| Cubelet RuntimeResource v1 proto、生成代码、descriptor 测试与 API 文档 | `40f4389a` |
| Agent capability negotiation 与 CubeShim 缓存/兼容解析 | `30bf3365` |
| 调用图、错误/幂等语义与契约探针 | `eb7aed1a`、`2e2612a4` |

接口定义包含 `GetCapabilities`、`PrepareSandbox`、`ReleaseSandbox`、`InspectSandbox` 和只报告的 `ReconcileSandboxes`。TAP FD 不进入 protobuf，继续通过 cubetap Unix socket 的 `SCM_RIGHTS` 交付。

## 验证

| 验证 | 结果 |
|---|---|
| `./tests/s0-interface-contract/run.sh` | `S0_4_INTERFACE_CONTRACT_OK`；Go descriptor、两份 Health proto、禁止递归方法/依赖、Shim/Agent 定向测试和格式检查通过 |
| `make shim-test` | CubeShim 76 项、cube-runtime 1 项通过，0 失败 |
| builder 内 `cargo test --manifest-path agent/Cargo.toml -p cube-agent` | 114 项通过，0 失败 |
| `git diff --check` | 通过 |
| 云节点环境检查 | TAT `inv-882hf6088t`、`inv-v82hib0njt`：本 PoC control 节点在线并保留 builder image；宿主无 Go/rg，契约 runner 已改为把全部检查放入 Docker/ctr builder |

平台在执行前拒绝了本地分支归档上传，因此 S0.4 未在云节点重放，云端也未产生该归档或源码变更。该限制不影响本阶段结论：S0.4 只验证 protobuf、依赖边界和编译期 capability 契约，不使用 KVM、CNI 或 Guest 数据面；这些真实环境能力已由 S0.1～S0.3 验证。S1 的 VM 生命周期仍必须在本 PoC 云节点验收。

## 审查门禁

进入 S1 前，独立 subagent 必须检查上述提交、契约边界、测试证据和未决问题更新，并明确返回 `APPROVE`。
