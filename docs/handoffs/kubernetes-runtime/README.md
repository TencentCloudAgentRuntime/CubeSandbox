# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.3 `IN_PROGRESS`：S1.2 标准 OCI Task 已完成；当前开始接通 kubelet/CRI 的 logs、非 TTY exec 和 termination grace period。

## 基线

最后一项已验证实现 commit 为 `d47af8c213f802a3f0cd69593752d1f9c560c3ad`，完整 tree 为 `17224716902ca1ace56c1d68915bbb31c5a766d8`。S1.2 rootfs bridge/probe 起点为 `9c679855`、`cf07e446`，Task API v3、稳定 rootfs 父 inode 和 Agent 信号退出码修复分别为 `781cd8f8`、`32a49105`、`d47af8c2`。

## 已完成

S0、S1.1、S1.2 均为 `DONE`。S1.2 已让 containerd 2.3.4 标准 overlayfs `CreateTaskRequest.rootfs` 在真实 Cube Guest 运行；同一 Sandbox/Cube VM 内连续 Task 自然退出 23、SIGKILL 返回 137。删除后 container、Task、Sandbox、Task 新增 snapshot、mount、shim、TAP/filter 和 active lease 残留全部为 0，验收前后的既有 snapshot 集合一致。同一 reviewer 已对实现修复、源码同步、严格构建、制品交付和真实终验逐项 `APPROVE`。

## 未完成

S1.3 尚未实现 kubelet/CRI 端到端 logs、非 TTY exec、termination grace period 和对应退出事件；S1.4 的 100 次清理、runc 共存和 legacy Cubebox 回归也未开始。因此 S1 Milestone 仍为 `IN_PROGRESS`。

## 验证

CubeShim 离线/locked 构建 115 项测试通过；Agent/workspace offline/locked 共 203 项通过，另有一个修改 TAT/Docker stdio UID 的环境用例显式过滤，信号转换 3 项在断网容器内点名通过。最终真实验收 `inv-9837xq0wnq` 为 `SUCCESS`：`S12_OCI_TASK_OK ... exit=23 killed=137`、`S12_HOST_RESIDUE_CLEAN ... active_leases=0`、`S12_STATIC_ANCHOR_CLEAN`。原始摘要、制品 SHA 和构建 invocation 见 `evidence/s1.2/README.md`。

## 阻塞

无外部阻塞。S1.3 的准确 CRI streaming/exec 调用路径和 CubeShim/Agent 最小增量仍需先做只读 trace；这属于本阶段工作，不是 blocker。S1.2 Agent 继续以 `seccomp=no` 构建，仅用于生命周期验证，不宣称 S3 seccomp 支持。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag`、对应私有 COS/TKE，不修改账号内其他资源；现有 S0/S1.1 云测资产不覆盖。

## 下一步

接手者先核对 `evidence/s1.2/README.md` 与终验 `inv-9837xq0wnq` 的 23/137 和零残留结论。随后在 S1.3 先只读追踪 CRI logs/exec/StopContainer 到 containerd Task/streaming API 的调用边界，冻结最小接口与失败清理；再按 logs、非 TTY exec、graceful signal/exit 事件三个小步实现，每步完成本地/云端测试并交同一 reviewer。不要提前展开 TTY/stdin 或 S1.4 的 100 Pod/legacy 回归。
