# S0.4 CubeShim、Cubelet 与 Agent 接口边界

## 结论

S1 采用“宿主 containerd 管 Kubernetes 生命周期，Cubelet 只管节点资源，Guest Agent 只管 VM 内执行”的边界。Cubelet 虽然在 legacy 产品中嵌入 containerd，但 Kubernetes 新链路不得调用其 CRI、Task、Sandbox、Image 或 Snapshot 服务。

S0.4 冻结两个 v1 契约：

- CubeShim ↔ Cubelet：`cubelet.services.runtime.v1.RuntimeResource`。
- CubeShim ↔ Agent：兼容扩展现有 `grpc.Health.Version`，返回 protocol version 与版本化 capability。

## 调用与所有权

```text
kubelet
  └─ host containerd
       ├─ image / snapshotter / CNI / Sandbox / Task 状态
       └─ CubeShim
            ├─ RuntimeResource gRPC ──> Cubelet node-resource adapters
            │                            ├─ VM assets / shared root
            │                            ├─ CNI netns attachment / TAP
            │                            └─ release / inspect / reconcile report
            ├─ cubetap Unix socket <── SCM_RIGHTS TAP FD
            ├─ embedded VMM
            └─ Health.Version + AgentService ──> Guest Agent
```

创建顺序为：host containerd 执行 CNI ADD → Sandbox Create 到 CubeShim → CubeShim 调用 `PrepareSandbox` → 通过 cubetap socket 获取一次性 TAP FD → 启动 VM → 查询 Agent capabilities → Agent `CreateSandbox`。删除时先停止 Guest Task/Sandbox 和 VM，再调用幂等 `ReleaseSandbox`，之后由 host containerd 执行 CNI DEL。

Cubelet 不回调 host containerd，也不调用自身嵌入的 containerd 来创建同一 sandbox。RuntimeResource 的 S1 service registration 不得依赖 `plugins.CRIServicePlugin`；只允许依赖网络、存储、cgroup、资产和本地状态 adapter。

## Cubelet RuntimeResource v1

源文件为 `Cubelet/api/services/runtime/v1/runtime.proto`，生成代码和 API 文档随仓库提交。

| 方法 | 作用 | v1 语义 |
|---|---|---|
| `GetCapabilities` | 协商 API 与 side channel | 必须返回 `service_mode=node-resources-only` 和 cubetap endpoint |
| `PrepareSandbox` | 准备资产、shared root、网络 attachment | 同 sandbox/generation/idempotency key 重试返回同一 lease；不创建 OCI Task |
| `ReleaseSandbox` | 释放指定 lease/generation | 不存在视为成功；旧 generation 不得释放新 generation |
| `InspectSandbox` | 查询持久化节点资源状态 | 只读，区分 not found、preparing、ready、releasing、released、error |
| `ReconcileSandboxes` | 比对调用方 live sandbox 集合 | v1 只报告 live、missing、orphan candidate；不得自动删除 |

`PrepareSandboxResponse` 返回可复用的 kernel、agent、guest image、shared root 与网络 attachment 描述。protobuf 只携带 TAP name/network handle，FD 不可序列化；CubeShim 用响应中的 endpoint 和 sandbox/tap identity 通过现有 `/data/cubelet/cubetap.sock` 获取 SCM_RIGHTS FD。

幂等规则：

- 同一 `sandbox_id + generation + idempotency_key` 返回相同 `lease_id`，并设置 `reused=true`。
- 同 generation 但期望资源不同，返回 `FAILED_PRECONDITION`。
- 更新 generation 前必须释放旧 lease；旧请求不能覆盖或释放新 generation。
- `UNAVAILABLE`、deadline 和连接断开允许用原 key 重试。
- 参数错误使用 `INVALID_ARGUMENT`，状态冲突使用 `FAILED_PRECONDITION`，内部可重试故障使用 `UNAVAILABLE`；Release 已不存在仍成功。

## Agent capability negotiation

Health proto 原字段保持不变：

- field 1：`grpc_version`
- field 2：`agent_version`
- field 3：`protocol_version`（新增）
- field 4：`capabilities`（新增，name + version）

当前 Agent protocol 为 1，声明 sandbox/container lifecycle、exec、stats、shared PID namespace、dynamic mount 与 passfd stdio。CubeShim 每次连接 Agent 都调用 `Health.Version`，拒绝空名称、零版本和重复 capability，并缓存版本表。

旧 Agent 不认识新增字段时返回 protocol 0/空列表，legacy Cubebox 继续运行；S1 的 Kubernetes handler 必须在创建 Pod 前检查其所需 capability，缺失时返回明确 `FailedPrecondition`，不能静默降级。未知 capability 必须忽略；已知 capability 采用“实际版本大于等于最低版本”判断。

## 代码组织与演进

S1 按以下位置实现，不复制 legacy workflow：

- `Cubelet/services/runtime/`：薄 gRPC adapter。
- Cubelet 内部资源接口：组合现有 network runtime、资产、storage/cgroup adapter；不得 import containerd client、CRI service 或 Task/Sandbox service。
- `CubeShim/shim/src/service/sandbox_srv.rs`：containerd Sandbox Service。
- CubeShim 节点资源 client：只消费 RuntimeResource v1 与 cubetap side channel。
- Agent/hypervisor 不理解 Kubernetes Pod、RuntimeClass、Deployment。

proto v1 只允许追加字段和 capability；字段删除必须 `reserved`。破坏性语义新建 v2。GPU、Snapshot/Restore、Pause/Resume 不加入本接口 v1；GPU后续单独 capability，快照体系在 S6 设计。

## S0.4 验证

`tests/s0-interface-contract/run.sh` 验证：

- 两份 Health proto 完全一致；
- RuntimeResource 方法集仅为节点资源操作；
- retry identity、generation 和 SCM_RIGHTS 边界存在；
- CubeShim 能解析 legacy/versioned capability 并拒绝重复项；
- Agent 返回唯一且非零版本的 capability；
- 未来 `Cubelet/services/runtime` 出现递归 containerd/CRI 调用时静态失败。
