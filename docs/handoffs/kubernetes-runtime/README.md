# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.1 `IN_PROGRESS`：实现一个 PodSandbox 对应一个 Cube VM。

## 基线

S0.4 实现 `695fbada`，第五轮复审 `APPROVE`，S0 收口 `8db49456`。

## 已完成

S0.1～S0.4 全部 `DONE`；Sandbox、OCI rootfs、Cilium 网络及 RuntimeResource/FD 契约均已有证据。

## 未完成

S1.1 尚未实现 Rust Sandbox Service 到 Cube VM 的完整 Create/Start/Stop/Shutdown/Wait/Status 链路。

## 验证

S0.4 Go test/race/vet、20 轮故障 race、官方 runner、VitePress 均通过；subagent `APPROVE`。

## 阻塞

无。S1.1 必须在本 PoC 云节点完成真实 VM 验收。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、相关文档；仅操作本 PoC 自建云资源。

## 下一步

确认 S1.1 验收契约，移植 Sandbox Service，接入 RuntimeResource 与 Cube VM，并在云节点重放；完成后交同一 subagent 审查。
