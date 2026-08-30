# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

`S0.1 Sandbox API`，状态 `VALIDATING`，Owner `Codex`。

## 基线

最后验证实现 `33dbf479`；CubeSandbox 基线 `09274501dd12e47dbed2dcc77d8eb67dd661d49c`。

## 已完成

containerd 2.3.4 双服务探针、固定 CRI 输入和一键脚本已落库；正常链路与四类明确异常在香港 PVM 节点通过，10 类残留均为 0。`K8S-OQ-001` 已决定。

## 未完成

等待 subagent 最终审查；未批准前不得开始 S0.2。Cube Guest、virtiofs 和 Cube-backed Task 属于 S0.2。

## 验证

实现侧 `go test -race ./...`、`go vet ./...` 通过；云端 TAT `inv-68246d0jt1` 为 `SUCCESS`。摘要与原始 trace 在 `evidence/s0.1/`，重放 `sudo CubeShim/sandbox-probe/scripts/verify-cloud.sh`。

## 阻塞

无技术阻塞；仅有用户要求的 subagent APPROVE 流程门。

## 受保护路径

`CubeShim/sandbox-probe/`、`docs/zh/dev/kubernetes-runtime-integration-development.md`、`docs/handoffs/kubernetes-runtime/`。

## 下一步

subagent 复核 `33dbf479`、TAT 与原始证据；若 APPROVE，将 S0.1 标记 `DONE`，单独更新 handoff 后进入 S0.2；否则修复并重审。
