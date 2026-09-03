# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S5.3 `IN_PROGRESS`：S3.4/S3.4d 已获同一 reviewer `APPROVE S3.4 DONE`，P0/P1/P2=0。
正确 RuntimeClass/overhead 模式已通过官方 `/configz` 定向门禁；首轮完整运行暴露
Guest 缺少 dummy netdev 的支持面内问题。PVM Guest kernel 修订版正在 builder 上由
`inv-b86w9i084p` 构建，尚未重新开始 477 项完整运行。

## 基线

最后一项已验证实现 commit 为 `1df1da09`；S3.4c 最终证据 commit 为 `24d2d188`。W1
当前 CubeShim/Agent ext4 SHA-256 为 `e0052c7e…`/`c768706b…`；`cube-runtime`
保持既有制品；运行时根为
`/opt/cubesandbox-s0-multinode-runtime-2269a3b3`。

## 已完成

S0、S1、S2、S3.1～S3.4d 均为 `DONE`。S3.4d 已关闭
`K8S-OQ-015/016/017/021`，完成生命周期 fence、受控 restart/resize/long-exec、
ephemeral-storage、QoS/多容器双层数值和最终清理；
两个 Worker 均为 0 sandbox/VM/CNI/shim/mount/active lease，集群 3/3 Ready。

## 未完成

S5.3 的 477 项完整 NodeConformance 尚未形成最终通过率、失败清单、清理证据和 reviewer
结论。memory EmptyDir 在 Guest 中呈现 FUSE mount identity 的兼容性缺口已确认，按
`K8S-OQ-025` 记录；不影响内容、权限和清理，但会失败于标准 `tmpfs` 类型断言。官方
`PrivilegedPod` 要求创建 dummy netdev，而仓库 x86 BM/PVM Guest config 均关闭
`CONFIG_DUMMY`；该支持面内缺口按 `K8S-OQ-028` 正在修复。

## 验证

S3.4d 最终验证：`inv-v86nregacb` 在 `10b7af56` 完成 identity replacement、service
163/163 与 all-targets；`inv-686nvg0va4`/`inv-886nvfg6v6` 将同一 Shim 部署到双 Worker；
`inv-686k7g02nv` 默认规格启动即 OOM 8/8 为 `OOMKilled/137`；
`inv-v86ksj0ndb` 完成 restart/两次 resize/受控长 exec；`inv-686ktxgext`、
`inv-886ku00590`、`inv-a86kufg720` 完成 Guest/Host 组合矩阵；
`inv-086ncr074p` 完成最终 lifecycle regression；`inv-a86ndt0pkt`/`inv-a86nds0c3q` 双
Worker exact zero；`inv-v86nea09kv` 为 3/3 Ready。完整证据见
[S3.4d 摘要](./evidence/s3.4/s3.4d-execution-summary.md)。

S5.3 已完成的关键验证：`1df1da09` 在 W1 的定向与全量回归通过；错误模式基线
`inv-686q27g8sp` 在 39 项中得到 33 通过、6 失败后主动终止，证明 containerd 缺省
handler 不会让 kubelet 计入 RuntimeClass overhead；`inv-b86t69gf00` 验证 Kubernetes
v1.36 原生 MutatingAdmissionPolicy 会在 `e2e-framework` namespace 注入 `cube` 且得到
256Mi overhead/节点选择器；`inv-386td0gr45` 的 7 项门禁为 6 通过、1 失败，标准
NodeConformance OOM、Downward API、privileged HostPath/subPath 均通过，唯一失败是不属于
NodeConformance 的 NodeAllocatable Host OOM 差异。`inv-b86w410u0n` 已证明官方测试能把
`/root/kubelet-config` 改为 30s、重启临时 unit，并恢复为 20s，结果 1/1 通过。
`inv-686tgvghci` 主动停止时为 32 通过、4 个实际失败和 1 个中断：两项已执行的 tmpfs
identity 差异、旧 kubelet 配置路径问题及 `PrivilegedPod` dummy netdev 缺口。新一轮前
`inv-b86w4kgh72` 的 Cube Sandbox/VM/shim/TAP/mount/active lease 全为 0。

## 阻塞

无外部阻塞或待用户决策。当前内部阻断为 `K8S-OQ-028`：需要完成 PVM Guest kernel
构建、W1 替换与启动验证，并通过官方 `PrivilegedPod` 单项门禁；不是权限或环境卡点。
P1 已知限制为持续长 exec + 同容器 resize 仍可能使首次
Update/探针超时；kubelet 重试后 resize 收敛，资源可精确清理。该组合不属于首版支持面，
在 `K8S-OQ-022` 转 S5.4 整改。另有 12 Sandbox 创建即取消的瞬时 `FailedKillPod`，重试
后 exact-zero，按 `K8S-OQ-023` 转 S5.4。二者均不阻断基础 E2E。

当前 W1 的临时测试状态必须成组恢复：默认 runtime 已是 runc；
`96-cubesandbox-e2e-nodeconformance.toml` 临时启用 Cube privileged 并把官方
`test-handler` 映射到 runc；kubelet 由等价的 `kubelet-e2e.service` 运行；集群中只对带
`e2e-framework` 标签 namespace 生效的 `cubesandbox-e2e-runtimeclass` mutation
policy/binding 正在启用；临时 auth carrier 和两项 ClusterRoleBinding 正在启用。control
和 W2 kubelet 仍停止、对应 Node 对象仍从 API 暂时移除，CVM 没有删除。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。
云端仅操作本 PoC 创建的资源；名称带“勿删”的 CVM/TKE 不得删除。现有证据、构建产物和
回滚副本不得覆盖，handoff 不记录凭证。

## 下一步

1. 完成 `inv-b86w9i084p` 的 PVM Guest kernel 构建，核对内嵌配置和 artifact SHA-256，
   在 W1 可回滚替换后通过官方 `PrivilegedPod` 单项门禁。
2. 重新执行 477 项完整 NodeConformance，保留 JUnit/Ginkgo JSON/日志摘要并逐项分类；只
   修复阻断主路径的问题，非严重差异按问题 ID 延期。
3. 清理 e2e namespace 后确认 W1 exact-zero；依次删除 mutation policy/binding、恢复
   `kubelet.service`、删除 e2e containerd 片段、删除 auth carrier/SA/RBAC；随后启动
   control/W2 kubelet，等待 3/3 Ready，并再次做双 Worker exact-zero。
4. 更新 S5.3 证据，运行 `make handoff-validate`，交给同一 reviewer 审计，未获批准前
   不得标记 S5.3 `DONE`。
