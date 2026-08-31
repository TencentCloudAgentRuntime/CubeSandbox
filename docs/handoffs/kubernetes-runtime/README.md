# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.2 `IN_PROGRESS`：S1.1 真实 Cube VM 生命周期已收口，开始打通标准 OCI 单容器 Task 生命周期。

## 基线

S1.1 最后验证实现 `22716267`（本地完整 tree `6e94b184ac065d43d2405b50e35598a146c9ea31`）；两台自建 CVM 的云测源码投影 tree 均为 `6e3b76eb94f378d5a8c2b02368c2dd28f6f2d90b`；S0 收口 `8db49456`。S1.2 尚无实现提交。

## 已完成

S1.1 `DONE`：Sandbox 生命周期、RuntimeResource lease/FD handoff、Cilium attachment、失败回滚和 dead-shim 恢复已经实现。containerd 2.3.4 的 public Platform wrapper 缺失时仅对 `Unimplemented` 使用 bootstrap v3 直连 ttrpc fallback；Cilium 网关邻居/直连路由和 Stop 后 Shutdown 重入问题已经实机修复；最终 reviewer `APPROVE`。

## 未完成

S1.2 尚未完成标准 OCI rootfs 到 Guest 单容器 Create/Start/Wait/Kill/Delete 的纵向链路和云端验收。

## 验证

源码同步验证 `inv-8831v50a2j`、`inv-9831v30ak5` 均成功。严格 CubeShim 构建 `inv-b831vp0wan` 成功，二进制 SHA-256 `805658814730f6440b1ee8d281c8e84ef7f07f5543378d844feb78df984812ff`。真实生命周期及回滚终验 `inv-38324c05ra` 成功：Create→Created Status→Platform→Start→Ready Status→Stop→Stopped Status→Wait→Shutdown；预期失败回滚后 TAP/tc/shared mount/adapter/reaper/shim 和 active lease 均为零，保留 2 条 durable tombstone lease record，anchor 已删除。

## 阻塞

无外部阻塞。S1.1 Agent 资产以 `seccomp=no` 构建，只用于生命周期验证；不构成 S3 seccomp 支持结论。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、相关文档；仅操作本 PoC 自建云资源。

## 下一步

梳理现有 Task Service、standard rootfs adapter 和 Guest Agent 进程契约；冻结 S1.2 最小改动与验收矩阵，再实现并用隔离 containerd + 真实 Cube VM 验证 Create/Start/Wait/Kill/Delete。
