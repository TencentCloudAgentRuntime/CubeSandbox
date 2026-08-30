# Kubernetes RuntimeClass PoC 未决问题

| ID | 问题 | 当前假设 | Owner | 最迟 Stage | 状态 | 所需证据/最终决定 |
|---|---|---|---|---|---|---|
| K8S-OQ-001 | containerd 2.3 Sandbox API 的实际 CRI 调用顺序和配置字段是什么？ | 使用 `sandboxer = "shim"`，CubeShim 同时承载 Sandbox/Task | Codex | S0 | DECIDED | handler 使用 `runtime_type/runtime_path/sandboxer = "shim"`；bootstrap v3 返回 ttrpc endpoint，Sandbox/Task 同 PID；CNI ADD 在 Create 前，Stop 后 CNI DEL，再 Shutdown/delete。正常与四类异常的 10 类残留均为 0，证据 `inv-68246d0jt1` 和 `evidence/s0.1/` |
| K8S-OQ-002 | VM 启动后新增 bind mount 是否能被固定 virtiofs shared root 稳定看到？ | 每 Pod 一个固定 shared root 可支持动态容器/卷 | Codex | S0 | DECIDED | `cache=never/read_only=true/announce_submounts=false` 下 bind、rename、只读立即可见；普通 live unmount 可能因 virtiofsd inode 引用 `EBUSY`，必须 Guest-first 解除消费、Host `MNT_DETACH`、generation 路径不复用。Task/VM 删除后引用及 mount 为 0；证据 `inv-9827ikgt4f` |
| K8S-OQ-003 | PoC 网络首先采用哪种数据面？ | 先用 Cilium，保留 VPC-CNI/Global Router adapter | 待指定 | S0 | OPEN | Pod IP、Service、DNS、NetworkPolicy、跨节点实测 |
| K8S-OQ-004 | Kubernetes 路径能否完全使用标准 `CreateTaskRequest.rootfs`？ | 可以，legacy 私有注解只服务原链路 | Codex | S0 | DECIDED | 可以。CubeShim 解析标准 overlay active snapshot，按 active upper + image lowers 原序导出并内部适配当前 Agent；CRI/containerd 不提供私有 rootfs 输入。20/20 创建删除无残留。Guest 临时 upper 不回写 containerd 的限制在 S3 处理；证据 `inv-9827ikgt4f` |
| K8S-OQ-005 | Cubelet 节点 RPC 的最小边界是什么？ | 只做 VM/网络资产准备、释放和对账 | 待指定 | S1 | OPEN | 接口草案和现有插件复用评审 |
| K8S-OQ-006 | PoC VM 规格如何确定？ | 固定 1 vCPU/256 MiB；生产再做资源聚合 | 待指定 | S1 | OPEN | 最小 Guest 开销和典型 workload 测量 |
| K8S-OQ-007 | ConfigMap/Secret 动态更新能否透过 virtiofs 保持语义？ | PoC 先保证启动注入 | 待指定 | S3 | DEFERRED | symlink swap、cache、inotify 与更新延迟测试 |
| K8S-OQ-008 | Snapshot/Restore CRD 和 artifact 格式如何定版？ | 二期优先从快照创建新 Pod | 待指定 | S6 | DEFERRED | 多容器一致性、远端存储和 CSI snapshot PoC |
