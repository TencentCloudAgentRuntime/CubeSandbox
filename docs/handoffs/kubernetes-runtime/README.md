# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.2 `BLOCKED`：标准 OCI 单容器 Task 实现和 probe 已完成并通过 reviewer；等待新源码/vendor 对象的私有 COS 上传授权后执行云端构建与真实 Cube VM 验收。

## 基线

S1.2 最后实现 `cf07e446`（完整 tree `c49c87d2afaea4ae90517a223c349bffdb86f246`），rootfs bridge 实现 `9c679855`；两台自建 CVM 的云测源码投影仍为 S1.1 tree `6e3b76eb94f378d5a8c2b02368c2dd28f6f2d90b`；S1.1 最后验证实现 `22716267`，S0 收口 `8db49456`。

## 已完成

S1.1 `DONE`。S1.2 已实现 managed Sandbox Task 的标准 OCI rootfs bridge、共享 root 严格校验、并发 Create/Shutdown fence 和跨 generation 安全清理；已新增真实 OCI Task probe，覆盖自然退出 23、SIGKILL 137、stdout、mount 生命周期及异常清理。实现和 probe 分别经过多轮同一 subagent review，最终均为 `APPROVE`。

## 未完成

S1.2 尚未完成严格云端构建和标准 OCI rootfs 到真实 Guest 的 Create/Start/Wait/Kill/Delete 验收，因此不能标记 `DONE`。

## 验证

S1.2 本地 `cargo check --tests` 通过；目标 `s12-oci-task-probe` 的 Go test、vet、build 通过。云端只读基线核对 `inv-6833mh023e`、`inv-0833mh0qv8` 均成功：只操作自建 `ins-pl7mznaa` 与 `ins-4dyul5ag`，两端 tree 均为 `6e3b76eb94f378d5a8c2b02368c2dd28f6f2d90b`、无 unstaged/untracked 内容。S1.1 严格构建 `inv-b831vp0wan` 和真实终验 `inv-38324c05ra` 仍是最后一项云端闭环证据。

## 阻塞

平台审批拒绝上传两个新的私有 COS 对象，因为此前用户授权仅覆盖另一个特定补丁包；审批明确禁止改用 TAT 内嵌等方式绕过。待授权对象为源码归档 29,458,366 bytes、SHA-256 `c6509cf895b8fbdf7fc3ba922c1435df78c0b801ec7b18dad6a8c2fd0cfdcdaf`，以及 sandbox-probe vendor 归档 4,464,250 bytes、SHA-256 `e69a4484cf4544dc83300a21dc450e356853adfc2a577b939c318b5ee1665168`；目标为既有私有 bucket 的 `s12/source/` 与 `s12/vendor/`。未上传任何新对象。S1.1 Agent 资产仍以 `seccomp=no` 构建，只用于生命周期验证。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、相关文档；仅操作本 PoC 自建云资源 `ins-pl7mznaa`、`ins-4dyul5ag` 及既有私有 COS，不修改其他账号内资源。

## 下一步

取得上述两个精确对象的上传授权；上传后在两台自建 CVM 的新 S1.2 目录物化 tree `c49c87d2afaea4ae90517a223c349bffdb86f246`，不覆盖 S1.1 目录。先在 build CVM 完成 Rust lib test/check/release build 与 Go race test/vet/build并交 reviewer，随后仅在 runtime CVM 以隔离 containerd + 真实 Cube VM 验证自然退出 23、SIGKILL 137、stdout、mount/Task/Sandbox 全量清理，再交 reviewer。
