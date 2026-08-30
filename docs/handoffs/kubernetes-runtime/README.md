# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

`S0.2 RootFS/virtiofs`，状态 `VALIDATING`，Owner `Codex`。

## 基线

实现 `c014d3c6`；证据 `929739af`；CubeSandbox 基线 `09274501dd12e47dbed2dcc77d8eb67dd661d49c`。

## 已完成

标准 containerd overlay active snapshot 已通过 opt-in annotation 转为 Guest 分层只读 rootfs；动态 bind、rename、只读与 detach 语义及 20 次循环已在香港 PVM 节点通过。

## 未完成

等待 subagent 独立审查；未获 `APPROVE` 前不得标记 `DONE` 或进入 S0.3。

## 验证

构建 TAT `inv-9827fk0njh`：69 tests 通过；验收 TAT `inv-9827ikgt4f`：`S0_2_ROOTFS_PROBE_OK`，残留全 0；证据见 `evidence/s0.2/`。

## 阻塞

无。普通 Host unmount 可能因 Guest stale inode 返回 EBUSY；已决定 S3 采用 Guest 先卸载、Host `MNT_DETACH`、路径不复用。

## 受保护路径

`CubeShim/`、`docs/zh/dev/kubernetes-runtime-integration-development.md`、`docs/handoffs/kubernetes-runtime/`。

## 下一步

subagent 复核实现、证据与 S0.2 验收；`APPROVE` 后更新 Stage/handoff 并进入 S0.3，否则修复后重审。
