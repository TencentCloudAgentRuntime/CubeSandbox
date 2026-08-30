# S0.4 CubeShim、Cubelet 与 Agent 接口边界

## 结论

S1 采用“宿主 containerd 管 Kubernetes 生命周期，Cubelet 只管节点资源，Guest Agent 只管 VM 内执行”的边界。Cubelet 虽然在 legacy 产品中嵌入 containerd，但 Kubernetes 新链路不得调用其 CRI、Task、Sandbox、Image 或 Snapshot 服务。

S0.4 冻结两个 v1 契约：

- CubeShim ↔ Cubelet：`cubelet.services.runtime.v1.RuntimeResource`，以及独立的 FD handoff v1 Unix 协议。
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
            │                            └─ durable lease / release / reconcile report
            ├─ FD handoff v1 Unix socket <── SCM_RIGHTS TAP FD
            ├─ embedded VMM
            └─ Health.Version + AgentService ──> Guest Agent
```

创建顺序为：host containerd 执行 CNI ADD → Sandbox Create 到 CubeShim → CubeShim 调用 `PrepareSandbox` → 按响应中的 lease 描述请求 TAP FD → 启动 VM → 查询 Agent capabilities → Agent `CreateSandbox`。删除时在同一线性化区内等待已开始的 FD duplicate、把该 lease 持久化为 `RELEASING` 并在解锁前使 FD handoff 失效，再停止 Guest Task/Sandbox、VM 和节点资源，最后完成 tombstone；host containerd 随后执行 CNI DEL。

Cubelet 不回调 host containerd，也不调用自身嵌入的 containerd 创建同一 sandbox。`Cubelet/services/runtime.Register` 直接接收 `grpc.ServiceRegistrar`，不接收 containerd plugin `InitContext`。其测试会解析 `go list -deps ./services/runtime/...`，禁止依赖 containerd 及 legacy Cubelet CRI/Task/Image/Snapshot 服务包。

## Cubelet RuntimeResource v1

源文件为 `Cubelet/api/services/runtime/v1/runtime.proto`，生成代码和 API 文档随仓库提交。

| 方法 | 作用 | v1 语义 |
|---|---|---|
| `GetCapabilities` | 协商 API 与 side channel | 返回 `service_mode=node-resources-only` 和 Kubernetes 专用 FD handoff endpoint |
| `PrepareSandbox` | 准备资产、shared root、网络 attachment | 持久化 generation、lease、handoff token；不创建 OCI Task |
| `ReleaseSandbox` | 释放指定 lease/generation | 只接受当前精确 lease 或其精确 tombstone 重试 |
| `InspectSandbox` | 查询持久化节点资源状态 | 只读，区分 not found、preparing、ready、releasing、released、error |
| `ReconcileSandboxes` | 比对调用方 live sandbox 集合 | v1 只报告 live、missing、orphan candidate；不得自动删除 |

`PrepareSandboxResponse` 返回 kernel、agent、guest image、shared root 与网络 attachment 描述。protobuf 不编码 TAP FD；`NetworkAttachment.fd_handoff` 返回 protocol version、endpoint 与绑定 token。

### 持久化状态机与 gRPC 结果

幂等键在单个 `sandbox_id` 内持久化并绑定操作类型、generation、lease 与目标摘要。`PayloadDigest` 是对规范化 `PodIdentity + ResourceRequest + NetworkIntent` 的摘要，不包含 idempotency key；S1 adapter 必须稳定序列化后再调用状态库。

| 当前持久化状态 | 请求 | 结果 |
|---|---|---|
| 无 active，`generation > high_watermark` | 新 `Prepare(key,digest,generation)` | 先持久化 `PREPARING`、新 lease 和 token，再执行副作用 |
| 任意 | 原 prepare key + 相同 generation/digest | 返回原持久化 lease，`reused=true`；已 tombstone 的 generation 返回 `FAILED_PRECONDITION`，不可复活 |
| 相同 active generation | 相同 digest、不同 key | `FAILED_PRECONDITION`，必须重用原 key |
| 相同 active generation | 不同 digest | `FAILED_PRECONDITION` |
| 任意 | key 被其他 generation、操作或目标使用 | `INVALID_ARGUMENT` |
| 有 active | 更高 generation 的 Prepare | `FAILED_PRECONDITION`，必须先释放当前 lease |
| 无 active | `generation <= high_watermark` 的 Prepare | `FAILED_PRECONDITION`，tombstone 防止旧请求复活 |
| `PREPARING` | 精确 generation/lease 的 ready | 持久化 `READY + network_handle`；相同重试成功，改变 handle 返回 `FAILED_PRECONDITION` |
| `READY` | 精确 generation/lease 的新 Release key | `BeginReleaseAndFence` 在线性化区内持久化 `RELEASING` 并删除 READY binding；返回后开始清理 |
| `PREPARING` | 精确 generation/lease 的新 Release key | 直接持久化 `RELEASING`；该 lease 从未发布 FD binding |
| current/tombstone | 原 release key + 精确 generation/lease | 幂等成功；即使已有更新 active lease，旧 tombstone 重试也不影响它 |
| 任意 | 错误 lease/generation 或同 lease 的新 release key | `FAILED_PRECONDITION` |
| 无记录或 future generation | Release | `NOT_FOUND`，且不得推进 high watermark |

缺失字段和非法 key 复用返回 `INVALID_ARGUMENT`；状态文件读取或持久化故障返回 `UNAVAILABLE`。网络/资源准备失败时，必须先清完副作用再调用 `AbandonPrepare` 写 tombstone。释放通过 `BeginReleaseAndFence` 执行：固定锁序为 Coordinator → Registry → Store；在持有 Registry 锁时持久化 `RELEASING`，成功则在解锁前删除 binding。rename 前的确定未提交失败保留 READY；rename 后的 open-parent/parent-fsync 失败标为 commit-unknown，立即删除 binding 并禁止 `CompleteRelease`，直到重试或 `RecoverSandbox` 精确校验 release identity 并成功执行 parent-directory fsync。之后才允许清理并写 tombstone。

进程重启后按持久化 phase 恢复：`PREPARING` 继续原 key 操作或在清理后 tombstone；`READY` 重新发布精确 FD binding；`RELEASING` 保持 fenced 并继续清理。状态库已覆盖 prepare/release 重试、错误 key/lease、重启恢复、tombstone high watermark 和旧请求不影响新 lease；S1 负责把资源 adapter 接入该状态机。

### FD handoff v1

Kubernetes endpoint 与 legacy `/data/cubelet/cubetap.sock` JSON 协议不同，legacy 行为不变。v1 每个 Unix 连接只处理一个请求：4 字节无符号大端 protobuf 长度（最大 64 KiB）加 `FDHandoffRequestV1`。请求必须同时匹配当前 `READY` binding 的：

- `sandbox_id`
- `generation`
- `lease_id`
- `network_handle`
- opaque `token`

校验与 TAP FD duplicate 在同一 registry 临界区内完成，replacement/release 无法插入其间。成功响应 code 为 `OK`、`fd_count=1`，通过 `SCM_RIGHTS` 携带恰好一个 fresh duplicate；重试可再次成功，但每次是新的 duplicate。客户端收到后拥有并关闭该 FD；服务端只拥有本次 duplicate，并在发送完成后关闭。`MALFORMED`、`UNAUTHORIZED`、`STALE`、`NOT_READY`、`INTERNAL` 均强制 `fd_count=0` 且不携带 ancillary FD。

监听 socket 使用文件 ACL；连接建立后必须提供 authorizer 并用 `SO_PEERCRED` 精确匹配配置的 CubeShim UID/GID，之后才查 lease 或打开 FD；authorizer 缺失时 fail closed。连接设置 1 秒 I/O deadline。Release 与 Acquire 的线性化点位于同一个 Registry 临界区：已进入 duplicate 的 Acquire 先完成；Release 在锁内持久化成功并删除 binding 后才返回，随后请求只得到 `STALE`。确定未提交的 pre-rename 失败保持 READY；post-rename/parent-fsync 的 commit-unknown 立即移除 binding，并在 `ConfirmReleaseDurable` 完成 parent-directory fsync 前阻止清理。若进程在持久化后崩溃，重启恢复不会发布 `RELEASING` binding。测试覆盖 replacement race、全部 fence 字段、released lease、合法重试、部分/超长/非法 frame、peer UID/GID，以及所有错误响应无 FD。

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

- `Cubelet/services/runtime/`：直接注册的薄 gRPC adapter、持久化状态机和 FD handoff；通过显式资源接口注入实现。
- Cubelet 内部资源接口：组合现有 network runtime、资产、storage/cgroup adapter；不得 import containerd client、CRI service 或 Task/Sandbox service。
- `CubeShim/shim/src/service/sandbox_srv.rs`：containerd Sandbox Service。
- CubeShim 节点资源 client：只消费 RuntimeResource v1 与 FD handoff v1。
- Agent/hypervisor 不理解 Kubernetes Pod、RuntimeClass、Deployment。

proto v1 只允许追加字段和 capability；字段删除必须 `reserved`。破坏性语义新建 v2。GPU、Snapshot/Restore、Pause/Resume 不加入本接口 v1；GPU 后续单独 capability，快照体系在 S6 设计。

## S0.4 验证

`tests/s0-interface-contract/run.sh` 验证：

- 两份 Health proto 完全一致；
- RuntimeResource 方法集仅为节点资源操作；
- prepare/release retry identity 与 FD 的五元 fence 字段存在；
- FD replacement/release race、peer credential、frame、FD 数量和所有错误路径；
- 持久化状态机在重启、tombstone、key/lease 冲突下的精确结果；
- CubeShim 能解析 legacy/versioned capability 并拒绝重复项；
- Agent 返回唯一且非零版本的 capability；
- RuntimeResource 直接 gRPC 注册，实际 Go import graph 不含 containerd 与 legacy Cubelet services。
