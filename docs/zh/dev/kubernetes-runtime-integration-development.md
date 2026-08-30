# CubeSandbox Kubernetes RuntimeClass PoC 开发计划

> 状态：执行中（S1.1 Sandbox VM 生命周期验证）
> 日期：2026-08-30  
> 总体设计：[CubeSandbox 对接 Kubernetes RuntimeClass 总体技术方案](./kubernetes-runtime-integration)  
> 活动交接：[Kubernetes RuntimeClass PoC Handoff](../../../docs/handoffs/kubernetes-runtime/README.md)

## 1. 开发目标

在不修改 Kubernetes/containerd 上游、不替换 CubeSandbox 现有产品链路的前提下，把现有 CubeShim 演进为可由 `RuntimeClass` 选择的 Pod VM runtime。PoC 最终需要证明：

- 一个 Pod 对应一个 Cube VM，init、app、sidecar 和 ephemeral container 可在 VM 内动态运行。
- 宿主机 containerd 负责标准 OCI image、snapshotter 和 CNI；CubeShim 消费标准 Sandbox/Task 输入。
- runc 与 Cube runtime 共存，现有 CubeMaster/CubeboxMgr 链路不回归。
- 网络、基础 PVC、常用安全字段、恢复、监控和升级路径能够被重复验证。
- Snapshot/Pause/Resume 的接口方向被记录，但实现放在二期。

## 2. 面向社区的实现原则

### 2.1 沿用现有组件边界

- **CubeShim** 是 containerd 适配层：承接 Sandbox/Task API，转换 OCI spec、rootfs、volume、stdio 和事件；不实现 Kubernetes controller。
- **Cubelet** 是节点资源层：准备/释放 KVM、Guest assets 和网络 attachment，并负责残留资源对账；不实现另一套 CRI。
- **Guest Agent** 是 VM 内容器执行层：管理 namespace、mount、cgroup 和进程；不理解 Pod、Deployment、RuntimeClass 等 Kubernetes API。
- **containerd/kubelet** 保持标准职责：镜像、snapshotter、CNI 和 Pod 状态机不复制到 CubeSandbox。
- **CubeMaster legacy 链路**继续可用，Kubernetes 功能通过独立入口和 feature gate 增量加入。

这能把 Kubernetes 特例限制在边缘适配层，核心 VM/容器能力仍可被其他 CubeSandbox 场景复用。

### 2.2 使用稳定契约而不是跨组件耦合

- 优先使用 containerd Sandbox API、Task API、OCI Runtime Spec 和 CNI 结果，不 fork 上游协议。
- CubeShim ↔ Cubelet、CubeShim ↔ Agent 的新增 RPC 必须版本化，并提供 `GetCapabilities`/feature negotiation。
- 新 protobuf 字段保持 optional/backward-compatible；先让接收方识别，再让调用方启用。
- 不支持的字段明确报错，不静默丢弃安全或生命周期语义。
- 实验能力默认关闭，通过配置或 RuntimeClass handler 打开；失败时可以退回 runc 或 legacy Cube 链路。

### 2.3 按组件拆 PR

一个 stage 可以由多个 PR 完成，但一个 PR 尽量只改一个组件：

1. 接口/文档 PR：协议、状态机、错误语义和测试计划。
2. Agent PR：Guest 侧能力，默认不被旧 Shim 调用。
3. CubeShim PR：Sandbox/Task 适配，通过 capability negotiation 启用。
4. Cubelet PR：节点本地资源服务和网络 adapter。
5. deploy/test PR：RuntimeClass、containerd 配置、安装器和 E2E。

重构与行为改动分开；不要在 Kubernetes PR 中顺便改 runtime type、重命名现有模块或替换旧存储格式。跨组件必须一起验证时使用 stacked PR，但每个 PR仍应可构建并说明依赖关系。

## 3. 建议代码组织

尽量在现有目录中扩展，避免建立一套平行实现：

```text
CubeShim/shim/src/
├── service/
│   ├── srv.rs                 # Shim 进程入口
│   ├── sandbox_srv.rs         # 新增：containerd Sandbox Service adapter
│   └── task_srv.rs            # 现有 Task Service，改为多 Task/sandbox
├── sandbox/                   # Pod VM 状态机、VM 生命周期、网络 attachment
├── container/                 # 单容器生命周期、rootfs、exec、stdio
└── recovery/                  # S4 再增加：状态持久化和 reconcile

Cubelet/
├── api/services/runtime/      # 版本化 Runtime Resource RPC 定义
├── services/runtime/          # 直接 gRPC 注册、持久化 lease 状态机、FD handoff
└── plugins/cube/runtime/      # 通过显式接口注入的 KVM/网络/资产 adapter

agent/
├── protoc/protos/agent.proto  # 兼容扩展动态容器/namespace/mount RPC
└── cube/src/                  # Guest rootfs、namespace、cgroup 和进程实现

deploy/kubernetes/runtimeclass/
├── runtimeclass.yaml
├── containerd-config.toml
└── README.md

tests/e2e/kubernetes-runtime/
├── manifests/
├── lifecycle/
├── network/
├── storage/
├── security/
└── recovery/
```

目录名称在第一个接口 PR 中由维护者最终确认。必须保持的边界是：Kubernetes API 不进入 Agent/hypervisor；containerd/CNI 适配不进入 Guest；CubeMaster 不成为 Pod 创建的同步依赖。

## 4. Stage 总览

| Stage | 目标 | 主要产物 | 进入下一 Stage 的条件 |
|---|---|---|---|
| S0 | 消除四个架构风险 | 技术探针、调用 trace、接口草案 | Sandbox API、rootfs/virtiofs、CNI 和组件边界均有可行证据 |
| S1 | 单容器纵向链路 | RuntimeClass + 单容器 Cube Pod | 创建、运行、日志、exec、停止、删除可重复通过 |
| S2 | 完整多容器生命周期 | init/app/sidecar/ephemeral + namespace | 多容器顺序、重启、探针和退出状态正确 |
| S3 | 存储、安全和资源 | volume/PVC、安全字段、双层 cgroup | 支持矩阵主路径通过，不支持项明确拒绝 |
| S4 | 恢复和可观测性 | 重连、reconcile、stats、metrics | 组件故障注入后无错误状态和持久泄漏 |
| S5 | 可部署 PoC 验收 | 安装升级、性能、兼容性、Node E2E | PoC 验收报告和已知限制完整 |
| S6 | 二期快照能力 | Snapshot/Restore CRD、Pause/Resume | 从快照创建新 Pod 和一致性验证通过 |

### 4.1 执行状态规则

本文档同时是 Stage 进度的唯一权威来源；handoff 只引用当前 `Sx.x`，不复制整张进度表。

| 状态 | 含义 |
|---|---|
| `NOT_STARTED` | 尚未开始 |
| `IN_PROGRESS` | 正在实现，尚未进入完整验收 |
| `VALIDATING` | 实现已具备，正在执行该 Work Stage 的验收标准 |
| `DONE` | 全部验收标准通过，并已填写可复现证据 |
| `BLOCKED` | 存在阻塞，必须在“下一步”中写解除条件 |
| `DEFERRED` | 不阻塞当前 Milestone，已明确新的目标 Stage |

`Sx` 的状态由必需的 `Sx.x` 聚合：只有全部为 `DONE` 才能标记 Milestone 完成。代码合入但尚未通过验收时只能是 `VALIDATING`。

### 4.2 当前准备状态

| 项目 | 状态 | 已完成 | 证据 | 下一步 |
|---|---|---|---|---|
| 方案与开发准备 | `DONE` | 总体设计、S0～S6 开发计划、轻量 handoff 和未决问题表 | `95b3164a`、`3b564b76`；VitePress 构建通过 | 从 S0.1 开始技术探针 |

## 5. S0：架构技术探针
> Milestone 状态：`DONE`。S0.1～S0.4 均已通过独立审查。

| Work Stage | 状态 | Owner | 已完成 | 验收证据 | 下一步 |
|---|---|---|---|---|---|
| S0.1 Sandbox API | `DONE` | Codex | 双服务探针、独立配置、固定 CRI 输入和一键验收脚本已提交；真实正常链路及四类明确异常通过，10 类残留均为 0 | 实现 `f38622c2`、`6a53a52d`、`33dbf479`；TAT `inv-68246d0jt1`；[原始证据](../../handoffs/kubernetes-runtime/evidence/s0.1/README.md)；subagent `APPROVE` | S0.2 RootFS/virtiofs |
| S0.2 RootFS/virtiofs | `DONE` | Codex | 标准 OCI active snapshot 已在真实 Cube Guest 运行；动态 bind/rename/只读与卸载约束已验证；20 次创建删除无残留 | 实现 `c014d3c6`；TAT `inv-9827ikgt4f`；[原始证据](../../handoffs/kubernetes-runtime/evidence/s0.2/README.md)；subagent `APPROVE` | S0.3 CNI 网络 |
| S0.3 CNI 网络 | `DONE` | Codex | Cilium tcfilter/TAP 跨 netns FD 已接入；Pod IP/MAC/MTU、DNS、Service、跨节点和 NetworkPolicy 通过，成功/失败资源残留均为 0 | 实现 `e16411fd`、`80bacacb`、`168cd061`；完整验收 `inv-a82g9g0x1f`；[原始证据](../../handoffs/kubernetes-runtime/evidence/s0.3/README.md)；subagent `APPROVE` | S0.4 组件接口 |
| S0.4 组件接口 | `DONE` | Codex | RuntimeResource v1、持久化 lease 状态机、带 generation/lease/token 栅栏的 FD handoff、直接 gRPC 注册、Agent capability negotiation 已实现；四轮问题均已整改 | 实现 `40f4389a`、`30bf3365`、`eb7aed1a`、`2e2612a4`、整改 `ea192ecb`、`e3205220`、`aace4c4a`、`695fbada`；[验收证据](../../handoffs/kubernetes-runtime/evidence/s0.4/README.md)；第五轮 subagent `APPROVE` | S1.1 Sandbox VM 生命周期 |

### S0.1 云上开发基线（2026-08-30）

| 项目 | 结果 |
|---|---|
| 节点 | 腾讯云香港二区 `ins-pl7mznaa`，`SA5.4XLARGE32`（16C32G），镜像 `img-qansmwme`，Ubuntu 24.04；带 `billing=blakezyli` 标签 |
| PVM/KVM | 内核 `6.12.33+`，`kvm_pvm` 已加载，`/dev/kvm` 可用；`KVM_GET_API_VERSION=12`、`KVM_CREATE_VM=ok` |
| containerd | 官方校验后的 `v2.3.4`，systemd 使用 `/usr/local/bin/containerd`；CRI images/runtime 插件均为 `ok`；Docker 29.2.1 正常接入同一 containerd |
| 存储 | 新 200GB 数据盘 `/dev/vdb` 以 XFS 挂载到 `/data/cubelet`，`reflink=1`，写入 `/etc/fstab` |
| 源码与构建 | 云节点从公开 `master` 检出精确基线 `09274501dd12e47dbed2dcc77d8eb67dd661d49c`；`make shim` 生成 `containerd-shim-cube-rs` 和 `cube-runtime` |
| 测试 | `make shim-test`：shim 61 个、cube-runtime 1 个测试通过，0 失败；构建 TAT `inv-38221eg40s`，测试 TAT `inv-6822eegkw4`，汇总 TAT `inv-3822g20r7i` |
| 网络/访问 | 复用账号内现有 `cubesandbox-cluster-subnet` 和共享安全组 `sg-k3absy6z`（均非本 PoC 创建）。TAT Agent 在线；公网 SSH 转发返回 `502 Server UnReachable`，当前以 TAT 执行命令，不阻塞自动化验证 |
| 集群 | 已确认香港地域可创建 Kubernetes 1.36.2；为避免在架构探针前扩张成本，尚未创建专属 TKE 集群 |

上述基线当时只证明云上开发环境、KVM API 和现有 CubeShim 可构建/可测试；后续 Sandbox API trace 与清理结论见下一节。完整 Cube Guest 和 virtiofs 仍由 S0.2 验证。

### S0.1 Sandbox API 探针结果（2026-08-30）

探针位于 `CubeShim/sandbox-probe`，必须单独构建，不进入默认产物。它采用 containerd
2.3.4 的 bootstrap v3，在一个 ttrpc endpoint 同时注册 Sandbox Service 与官方
runc Task v3 Service。此处复用 runc 只用于隔离验证 containerd 契约；S1.1 必须把
这些契约移植到 Rust CubeShim，并替换为 Cube-backed Task，之后删除 Go 探针。

| 项目 | 结果 |
|---|---|
| 配置 | 独立 root/state/socket，不替换节点主 containerd；handler `cube-s0` 使用 `runtime_type = "io.containerd.cube-s0.v1"`、绝对 `runtime_path` 和 `sandboxer = "shim"` |
| 正常链路 | CNI ADD → bootstrap v3 → Sandbox Create/Start/Wait → Sandbox Status/Platform → Task v3 Create/Start/Wait/Kill/Delete → Sandbox Stop → CNI DEL → Sandbox Shutdown → shim delete |
| CRI 结果 | `SANDBOX_READY`，Pod IP `10.88.0.11`；BusyBox 标准 OCI snapshot 进程输出 `cube-s0-task-ok` 并准确返回 exit code 23 |
| 正常清理 | 删除后 CRI Pod/Container、mount、shim 进程/socket、sandbox metadata、state/root bundle、netns、host-local IP 分配 10 项均为 0 |
| 异常清理 | `CreateSandbox` 失败、`StartSandbox` 失败、Create 中 shim exit(86)、延迟 Create 后客户端取消均回到上述 10 项 0；每例均确认 failpoint 命中和 CNI ADD/DEL 成功 |
| 本地验证 | `go test -race ./...`、`go vet ./...`、`git diff --check` 通过 |
| 云端证据 | 仓库脚本完整重放 `inv-68246d0jt1`；原始 JSONL、失败输出和摘要位于 `docs/handoffs/kubernetes-runtime/evidence/s0.1/` |

实测确认以下非显然契约：

- Sandbox bundle 没有 pause 容器 `config.json`，不能直接复用 runc shim manager 的
  spec/grouping 启动逻辑；
- bootstrap 必须返回 `version=3, protocol=ttrpc`，Task 才会复用 Sandbox endpoint；
- `SandboxStatusResponse.state` 必须使用 CRI 枚举字符串
  `SANDBOX_READY/SANDBOX_NOTREADY`，自由文本 `ready/running` 会被映射为 NotReady；
- CNI ADD 在 Sandbox Create 前完成；Stop 时先清 Task 和 Sandbox，再执行 CNI DEL；
  Remove 阶段可能以空 netns 再调用一次 CNI DEL，因此 CNI DEL 必须幂等；
- Create/Start 失败由 shim controller 调用 Shutdown 并删除 shim/bundle；shim 已崩溃时
  Shutdown 可能失败，但 containerd 仍执行 shim delete；客户端取消由 CRI 回滚 CNI，
  最终同样不能残留 metadata、mount、socket 或进程。
- 首轮 crash 探针暴露出 delete helper 未删除死 shim socket；提交 `6a53a52d` 改为从
  `bootstrap.json` 读取精确地址并传播清理错误。新矩阵开始前只删除两个已验证不可连接
  的旧 socket，之后 normal、fail-create、fail-start、crash-create、cancel-create 每例
  均断言 socket=0。

S0.1 尚未证明 Cube Guest、virtiofs 或 Cube-backed Task；这些属于 S0.2，不能用本
探针中的 runc 成功结果代替。

### S0.2 RootFS/virtiofs 探针结果（2026-08-30）

探针位于 `CubeShim/s0-rootfs-probe`，由
`io.containerd.cube.s0.standard-rootfs=true` 显式开启。当前 Agent 仍消费 legacy
`cube.rootfs.info`，因此 CubeShim 在内部把标准 `CreateTaskRequest.rootfs` 转成该
注解；上游 containerd/CRI 不需要生成 Cube 私有 rootfs 输入。S1 把转换并入 Sandbox
生命周期后应删除或演进此 S0 开关。

| 项目 | 结果 |
|---|---|
| 云上环境 | 香港二区 `ins-pl7mznaa`；官方匹配 PVM Host/Guest 6.6.69；containerd 2.3.4；XFS `/data/cubelet` |
| 标准 rootfs | BusyBox 1.36.1 的 overlayfs active snapshot 经标准 Task rootfs 进入 Guest，输出 `STANDARD_OCI_ROOTFS_OK`，准确返回 exit code 23 |
| 转换方式 | 不导出 Host merged overlay；按 containerd 顺序 bind active upper + image lowers，Guest Agent 在其上建立临时 writable overlay |
| virtiofs 参数 | `cache=never`、`read_only=true`、`announce_submounts=false`；开启 submount 通告的负向对照在 Guest overlay 返回 `EINVAL` |
| 在线变化 | VM 启动后新增 bind、Host rename、切只读均由 Guest console 确认；写只读 bind 返回 `Read-only file system` |
| 在线卸载约束 | Guest lookup 后普通 Host unmount 返回 `EBUSY`；`MNT_DETACH` 使 Host mount 立即归零，旧 inode 可能保留到 Task/VM 删除。后续 volume detach 必须 Guest-first、generation 路径不复用 |
| 清理 | 动态用例和 20/20 创建删除完成后，mount、share、Task、Container、Shim 每项均为 0 |
| 测试/构建 | `make shim-test`：CubeShim 68 个、cube-runtime 1 个测试通过；release 构建通过，TAT `inv-9827fk0njh` |
| 最终验收 | 仓库脚本直接重放成功，TAT `inv-9827ikgt4f`；环境证据 TAT `inv-0827k8gnsw` |

由负向对照确认两个非显然边界：

- Host merged overlay 不能直接作为 Guest overlay lower，否则形成
  overlay-on-virtiofs-on-overlay 并返回 `EINVAL`；
- layer bind 必须关闭 `announce_submounts`，否则 Guest 把 lower 识别为 FUSE
  submount，同样返回 `EINVAL`。

Guest writable upper 当前不回写 containerd active upper。S0/S1 的运行、退出码与删除
语义已成立；持久化 writable layer、容器重启对账和 snapshotter 协同留到 S3。


### S0.3 CNI 网络探针结果（2026-08-31）

探针位于 `CubeShim/s0-cni-probe`。S0 使用 anchor Pod 保存 CNI netns，在其中创建 TAP 和双向 tcfilter；CubeShim 从该 netns 打开 TAP 并把 FD 交给嵌入式 VMM。S1 必须把 netns/attachment 来源改为 Sandbox Service 与 Cubelet network adapter，并删除 anchor 与 S0 annotation。

| 项目 | 结果 |
|---|---|
| 云上环境 | 香港二区 3 节点 Kubernetes 1.36.4、containerd 2.3.4、Cilium 1.20.0；隔离验收节点为 `ins-4dyul5ag`，匹配 PVM Host/Guest 6.6.69 |
| Pod 网络身份 | Guest 使用 CNI 分配的 Pod IP、MAC、MTU、/32 路由和网关；MAC/MTU 从目标 netns 的 netlink 读取，避免误读宿主机 sysfs |
| 数据面 | TAP 与 Pod eth0 使用双向 tc ingress redirect；跨 netns TAP FD 显式禁用 name-based ioctl 与 offload |
| Kubernetes 网络 | 跨节点 PodIP、Cluster DNS、Service ClusterIP 和 Cilium egress NetworkPolicy 全部通过 |
| OCI/DNS | 沿用 S0.2 标准 OCI rootfs；Pod DNS 同时进入 sandbox，并通过现有 custom-file 机制注入容器 `/etc/resolv.conf` |
| 异常与清理 | 相对 netns 路径在创建前明确失败；成功/失败后 Task、Container、Shim、TAP、tc filter、rootfs mount/dir 均为 0，测试 namespace 已删除 |
| 构建/测试 | 云端 release 构建与 74 项测试通过，TAT `inv-982ekw0q2u`；本地 `make shim-test` 通过 CubeShim 74 项和 cube-runtime 1 项测试；binary SHA-256 `4414ee5da24871978b65a34a04a2999430169b91e0f18f1163b90e14d6d43a10` |
| 最终验收 | anchor 对照 `inv-b82g3a0mda`；无网络对照 `inv-b82fadg4xe`；Cube 完整 CNI `inv-a82g9g0x1f`；最终集群状态 `inv-682gcjgsnu`；[原始证据](../../handoffs/kubernetes-runtime/evidence/s0.3/README.md) |

诊断同时确认 Host 6.12/Guest 6.6 的 reset 失败与网络无关；匹配 Host/Guest 6.6.69 后无网络与完整 CNI 用例均成功。S0 只冻结 Cilium tcfilter 作为首选 PoC 路径，VPC-CNI/Global Router 留给后续 adapter 兼容验证。

### S0.4 组件接口结果（2026-08-31）

S0.4 将 Kubernetes 新链路分为三层：host containerd 维护 CRI、OCI image/snapshot、Sandbox/Task 与 CNI 状态；Cubelet `runtime.v1.RuntimeResource` 只做节点资源 Prepare/Release/Inspect/report-only Reconcile；Guest Agent 只做 VM 内容器执行。Cubelet 的新 service 不得调用内嵌 containerd 的 CRI、Task、Sandbox、Image 或 Snapshot 服务。

| 项目 | 结果 |
|---|---|
| CubeShim ↔ Cubelet | v1 方法集、持久化 generation/lease/tombstone 和精确 gRPC 结果已冻结；Kubernetes 专用 FD handoff 以 generation + lease + network handle + token 栅栏后通过 `SCM_RIGHTS` 交付 |
| CubeShim ↔ Agent | 兼容扩展 `Health.Version` field 3/4；Agent protocol 1 声明版本化能力；legacy protocol 0 仍兼容旧 Cubebox，S1 Kubernetes handler 必须显式校验 capability |
| 递归防线 | RuntimeResource 直接注册到 `grpc.ServiceRegistrar`；测试解析真实 `go list -deps`，禁止依赖 containerd 与 legacy Cubelet services |
| 测试 | 契约探针输出 `S0_4_INTERFACE_CONTRACT_OK`；CubeShim 76 项、cube-runtime 1 项、Agent 114 项通过 |
| 云端范围 | 本 PoC control 节点与 builder image 经 TAT 确认在线；平台在执行前拒绝本地分支归档上传，因此本纯编译契约未在云端重放且云端未被修改。S1 真实 VM 生命周期仍在云节点验收 |

详细调用图、兼容规则和演进约束见 [S0.4 接口边界](./kubernetes-runtime-integration-s0.4-interface.md)，原始摘要见 [S0.4 验收证据](../../handoffs/kubernetes-runtime/evidence/s0.4/README.md)。

### 目标

只回答“主架构是否可行”，避免在调用顺序、rootfs、virtiofs 或网络尚未验证时展开完整实现。

### 工作项

- **S0-1 Sandbox API**：在 containerd 2.3 基线上记录 `RunPodSandbox`、Sandbox Service、Task Service、CNI 和清理的真实调用顺序；验证 `sandboxer = "shim"` 的最小配置。
- **S0-2 RootFS/virtiofs**：让 containerd overlayfs active snapshot 通过标准 `CreateTaskRequest.rootfs` 在 Guest 中运行；验证 VM 启动后新增 bind、rename、只读 mount 和 unmount。
- **S0-3 网络**：用一个候选 CNI 把 Pod netns/IP 接入 VM，验证 Pod-to-Pod、DNS、Service 和最小 NetworkPolicy。
- **S0-4 接口边界**：冻结 CubeShim ↔ Cubelet 最小 RPC 与 CubeShim ↔ Agent capability negotiation 草案，确认不会递归调用 Cubelet 内置 containerd。

### 验收标准

- 一份可复现的 containerd 配置和调用 trace，能指出每个失败阶段由谁清理。
- 一个标准 OCI rootfs 在 Cube VM 内运行，退出码返回 containerd；创建/删除 20 次无残留 mount。
- VM 启动后新增的 rootfs bind 在 Guest 可见，删除后引用被释放。
- 一个 Pod IP 对应一个 VM，基础 DNS/Service/跨节点路径至少在所选 PoC CNI 上跑通。
- `K8S-OQ-001`～`K8S-OQ-004` 更新为 `DECIDED`，或有证据表明需要修改总体架构。
- 不要求生产代码质量；探针代码若合入必须 feature-gated，并附删除或演进说明。

## 6. S1：单容器纵向 PoC
> Milestone 状态：`IN_PROGRESS`。S0.1～S0.4 已完成；当前执行 S1.1。

| Work Stage | 状态 | Owner | 已完成 | 验收证据 | 下一步 |
|---|---|---|---|---|---|
| S1.1 Sandbox VM 生命周期 | `VALIDATING` | Codex | Rust Sandbox Service、Cubelet RuntimeResource adapter/recovery、真实 Unix FD handoff 与 VM 失败回滚已实现；官方 containerd 跨语言 Create 成功，缺 KVM Start 精确释放 | `47522929`、`e7881524`；[验收证据](../../handoffs/kubernetes-runtime/evidence/s1.1/README.md) | 云端真实 Cube VM 成功链路、清理验收与 subagent 复审 |
| S1.2 OCI Task | `NOT_STARTED` | 待指定 | — | — | 打通单容器 Create/Start/Wait/Kill/Delete |
| S1.3 CRI 基础交互 | `NOT_STARTED` | 待指定 | — | — | 实现 logs、非 TTY exec、信号和退出码 |
| S1.4 清理与共存 | `NOT_STARTED` | 待指定 | — | — | 验证资源清理、runc 和 legacy 回归 |


### 目标

让用户通过 `runtimeClassName: cube` 运行一个标准单容器 Pod，并完成完整创建和删除闭环。

### 工作项

- CubeShim 实现最小 Sandbox Create/Start/Stop/Shutdown/Status。
- Task Service 使用标准 rootfs 创建一个 Guest 容器，支持 Start/Wait/Kill/Delete。
- Cubelet 提供最小 Prepare/Release/Inspect，返回 VM 资产和网络 attachment。
- 支持 CRI 日志、非 TTY `exec`、grace period 和准确 exit code。
- 提供 RuntimeClass、containerd 配置和专用节点 label/taint。

### 验收标准

- `Pod`、`Job`、单副本 `Deployment` 能创建并达到预期状态。
- `kubectl logs` 和非 TTY `kubectl exec` 正常；失败进程返回准确 exit code。
- 正常删除、强制删除和创建中取消都能最终释放 VM、tap、virtiofs、mount 和 socket。
- 连续创建/删除 100 个单容器 Pod，无持续增长的残留资源。
- runc 仍为默认 runtime；不指定 `runtimeClassName` 的 Pod 行为不变。
- legacy Cubebox 创建/删除 smoke test 通过。

## 7. S2：多容器与 Pod 生命周期
> Milestone 状态：`NOT_STARTED`。依赖 S1.1～S1.4 完成。

| Work Stage | 状态 | Owner | 已完成 | 验收证据 | 下一步 |
|---|---|---|---|---|---|
| S2.1 动态多容器 | `NOT_STARTED` | 待指定 | — | — | 在运行中的 VM 动态增删普通容器 |
| S2.2 Init 与重启 | `NOT_STARTED` | 待指定 | — | — | 实现 init 顺序和单容器重启 |
| S2.3 Namespace | `NOT_STARTED` | 待指定 | — | — | 实现 Pod 共享和隔离 namespace 语义 |
| S2.4 Sidecar 与 Pod 生命周期 | `NOT_STARTED` | 待指定 | — | — | 实现 sidecar、ephemeral、probe 和 hook |


### 目标

把一个 Cube VM 从“单容器沙箱”升级为符合 Kubernetes Pod 语义的动态多容器 sandbox。

### 工作项

- 支持 init container、普通容器、原生 sidecar 和 ephemeral container 动态增删。
- net/IPC/UTS 在 Pod 内共享；PID 默认隔离，支持 `shareProcessNamespace`。
- 每容器独立 mount namespace、rootfs、cgroup、stdio、日志和退出状态。
- 支持 startup/readiness/liveness probe、lifecycle hook、restart policy 和 graceful termination。
- 单容器重启不得重启 VM 或影响其他容器。

### 验收标准

- init 顺序、sidecar 启停顺序和 app 并发行为符合 Kubernetes 预期。
- 一个容器 crash 后只重建该容器；其他容器和 Pod IP 保持不变。
- 多容器日志可分别读取，exec 定位到正确容器。
- `shareProcessNamespace` 开关两种模式均有 E2E；hostPID/hostIPC/hostNetwork 明确拒绝。
- ephemeral container 能在运行中的 sandbox 动态加入并退出。
- 终止宽限期、SIGTERM/SIGKILL 和 TaskExit 事件时序有自动化测试。

## 8. S3：存储、安全与资源
> Milestone 状态：`NOT_STARTED`。依赖 S2.1～S2.4 完成。

| Work Stage | 状态 | Owner | 已完成 | 验收证据 | 下一步 |
|---|---|---|---|---|---|
| S3.1 基础 Volume | `NOT_STARTED` | 待指定 | — | — | 实现 emptyDir 和 projected 类 volume |
| S3.2 PVC | `NOT_STARTED` | 待指定 | — | — | 实现文件系统 PVC 挂载和清理 |
| S3.3 SecurityContext | `NOT_STARTED` | 待指定 | — | — | 映射并验证常用安全字段 |
| S3.4 资源控制 | `NOT_STARTED` | 待指定 | — | — | 实现 Host/Guest 双层 cgroup |


### 目标

覆盖用户首版要求的 volume、安全上下文和资源控制主路径。

### 工作项

- 支持 `emptyDir`、ConfigMap、Secret、projected volume、基础文件系统 PVC 和 allowlist `hostPath`。
- 支持 UID/GID、supplemental groups、capabilities、只读 rootfs、`no_new_privileges` 和 seccomp。
- privileged 使用节点开关与 Pod 请求双门禁，只在 Guest 内提权，不自动透传 Host 设备。
- Host VM cgroup 限制总资源；Guest cgroup 限制每容器资源。
- PoC 使用固定 VM 规格并测量开销；是否增加资源 admission 由数据决定。

### 验收标准

- 同一 volume 可按不同目标路径/只读属性挂载到多个容器。
- RWO 文件系统 PVC 可挂载、读写、卸载并在 Pod 删除后无引用泄漏。
- ConfigMap/Secret 启动注入正确；动态更新作为 `K8S-OQ-007` 单独记录，不伪装为已支持。
- UID/GID/groups、capability add/drop、readonly rootfs、seccomp 均有正反用例。
- privileged 未开启时请求被拒绝；开启后仍无法访问未授权 Host device/path。
- Host/Guest CPU、内存限制在压力测试中生效，OOM 能归因到正确 Pod/容器。
- raw block、完整 subPath、双向 mount propagation 等未实现能力返回明确结果并写入支持矩阵。

## 9. S4：恢复与可观测性
> Milestone 状态：`NOT_STARTED`。依赖 S3.1～S3.4 完成。

| Work Stage | 状态 | Owner | 已完成 | 验收证据 | 下一步 |
|---|---|---|---|---|---|
| S4.1 状态与重连 | `NOT_STARTED` | 待指定 | — | — | 定义最小持久状态并实现组件重连 |
| S4.2 Reconcile | `NOT_STARTED` | 待指定 | — | — | 对账并清理 VM、网络和 mount 资源 |
| S4.3 可观测性 | `NOT_STARTED` | 待指定 | — | — | 输出 logs、events、metrics 和 CRI stats |


### 目标

让 PoC 在组件重启和常见失败下保持可诊断、可清理，而不是只能在理想路径运行。

### 工作项

- 持久化最小 sandbox/container 状态并实现幂等操作。
- containerd、CubeShim、Cubelet 重启后重连存活 VM；节点重启由 Kubernetes 重建。
- 对 VM、tap、virtiofs、mount、socket 和 tombstone 做 reconcile。
- 输出 sandbox/容器事件、结构化日志、Prometheus 指标和 CRI stats。
- 统一 sandbox/container request ID，提供最小 inspect/diagnostic 命令。

### 验收标准

- 分别 kill/restart containerd、CubeShim、Cubelet，运行中的 Pod 要么恢复，要么进入明确失败并可被 kubelet 重建。
- Agent 断连能重试；超过阈值后状态明确，不无限卡住。
- CNI、mount、VM 删除故障可通过 reconcile 收敛，重复执行不会破坏其他 Pod。
- 故障注入后无跨 Pod 误删，残留资源数量回到基线。
- CRI stats 与 Host/Guest 原始数据误差在记录的容忍范围内。
- 每种失败至少能从日志或指标定位到具体生命周期阶段。

## 10. S5：PoC 集成交付
> Milestone 状态：`NOT_STARTED`。依赖 S4.1～S4.3 完成。

| Work Stage | 状态 | Owner | 已完成 | 验收证据 | 下一步 |
|---|---|---|---|---|---|
| S5.1 安装与共存 | `NOT_STARTED` | 待指定 | — | — | 提供安装、卸载和 runc 共存方案 |
| S5.2 升级与回滚 | `NOT_STARTED` | 待指定 | — | — | 验证版本协商、滚动升级和回滚 |
| S5.3 兼容性 | `NOT_STARTED` | 待指定 | — | — | 运行 Node E2E/Conformance 并分类失败 |
| S5.4 性能与稳定性 | `NOT_STARTED` | 待指定 | — | — | 执行密度、并发和 soak 测试 |


### 目标

形成可安装、可回滚、可重复演示的 Kubernetes runtime PoC，并给出是否进入生产化的证据。

### 工作项

- 节点安装/卸载、containerd 配置合并、RuntimeClass、label/taint 和版本兼容检查。
- runc/Cube 混部、cordon/drain、滚动升级和回滚。
- Kubernetes Node E2E/Conformance 结果分类。
- 多容器、PVC、监控、故障恢复和升级的完整回归。
- 性能、密度和稳定性测试。

### 验收标准

- 在至少 5 节点集群可重复安装、升级、回滚；现有 containerd 配置不被覆盖。
- runc 系统 workload 与 Cube Pod 同时稳定运行。
- 单节点 100 Cube Pods、10 并发创建完成测试，记录 P50/P95/P99、失败率和资源开销。
- 运行 24～72 小时 churn/soak，无持续资源泄漏或状态漂移。
- Node E2E/Conformance 每个失败项都有分类和链接，不用笼统豁免。
- 形成 PoC 验收报告：支持矩阵、已知限制、升级/回滚步骤和生产化建议。
- 100 节点验证是否执行取决于资源条件；未执行时明确记录为生产化前置项，不把它算作 PoC 通过证据。

## 11. S6：二期 Snapshot、Restore 与 Pause/Resume
> Milestone 状态：`NOT_STARTED`。依赖 S5.1～S5.4 完成，属于二期范围。

| Work Stage | 状态 | Owner | 已完成 | 验收证据 | 下一步 |
|---|---|---|---|---|---|
| S6.1 Snapshot Artifact | `NOT_STARTED` | 待指定 | — | — | 定义并生成版本化多容器快照制品 |
| S6.2 Restore 新 Pod | `NOT_STARTED` | 待指定 | — | — | 通过 CRD/annotation 恢复为新 Pod |
| S6.3 Pause/Resume | `NOT_STARTED` | 待指定 | — | — | 实现短时暂停恢复和失败收敛 |


### 目标

在标准 Pod 生命周期稳定后，增加 Cube 特有的快照能力，优先支持从快照创建新 Pod。

### 工作项

- 定义 `CubeSandboxSnapshot` 和操作 CRD/controller。
- 生成多容器 rootfs/写层、VM memory/device state 和兼容性 manifest。
- 对接远端 artifact storage；PVC 一致性通过 CSI VolumeSnapshot 协调。
- Pod annotation `cubesandbox.io/restore-from` 引用已授权的不可变 artifact。
- 实现短时受控 Pause/Resume；长暂停语义最后评估。

### 验收标准

- 多容器 Pod 可制作快照并在兼容节点恢复为新 Pod。
- 新 Pod 使用新 UID、sandbox ID 和 Pod IP；容器文件系统和进程状态符合定义的一致性级别。
- Secret 不进入 artifact，PVC snapshot 引用可验证。
- 不兼容 CPU/Guest/Agent/Shim/snapshot format 时在启动前明确拒绝。
- 上传中断、恢复失败和 artifact 损坏均有回滚/错误状态。
- Pause 超时后能够恢复或失败收敛，不让 Pod 永久卡在中间状态。

## 12. Stage 执行与 Handoff

Stage 进度只记录在本文各 `Sx.x` 状态表中；活动 handoff 只保存当前工作入口，不再复制整项进度。详细规则见 [PoC Handoff 规则](../../dev/handoff-policy.md)。状态变化时按以下顺序更新：

1. 直接更新对应 `Sx.x` 行的状态、Owner、已完成内容、验收证据和下一步。
2. 在活动 handoff 中写当前 `Sx.x`、基线 commit、最后一项验证、阻塞和接手动作。
3. 在 `open-questions.md` 更新该 Work Stage 必须关闭的问题。
4. 附可复现命令和结果摘要；接手者先复现最后一项关键验证。

Work Stage 未达到全部验收标准时不能标记 `DONE`。允许以 `DEFERRED` 延期非关键项，但必须注明新的目标 Stage；会改变主架构或公共接口的问题不能带入不可逆实现。


## 13. 未确认问题记录规则

权威清单是 `docs/handoffs/kubernetes-runtime/open-questions.md`。新增问题使用连续 ID：

```text
K8S-OQ-009 | 问题 | 当前假设 | Owner | 最迟 Stage | OPEN | 需要的证据
```

状态流转：

```text
OPEN -> VALIDATING -> DECIDED
  └----------------> DEFERRED -> OPEN
```

- `OPEN`：知道问题，但还没有足够证据。
- `VALIDATING`：已经有 owner 和正在执行的探针/测试。
- `DECIDED`：证据和最终选择已写入最后一列，历史行保留。
- `DEFERRED`：当前 stage 不阻塞，并明确了新的解决 stage。

如果实测推翻本文档的假设，先更新问题记录和总体设计，再改实现；不允许让代码成为唯一的事实来源。
