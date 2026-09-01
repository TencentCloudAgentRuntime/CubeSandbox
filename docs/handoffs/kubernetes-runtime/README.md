# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4a `IN_PROGRESS`：S3.3 SecurityContext 已完成；当前冻结 Kubernetes/CRI/OCI 到 Host Pod VM 与 Guest per-container cgroup 的资源输入、现状和 create/update 缺口。

## 基线

最后一项已验证实现 commit 为 `7bf7f09d69d7bde8b0553c2231ff16d6111880b7`，tree 为 `1d028a40df6265a11f6c270c9fa38f5681d9e748`；S3.3f 脚本与证据提交为 `92a4fa56d431b9f0cb029bb3c960b2464972f777`，tree 为 `66267a147e3a62bddc95539a5295dada0782b44a`。正式 E2E/审计脚本 SHA-256 为 `86cc6a11…`/`972e9962…`；live Shim 为 `3c715652…`，Agent ext4 为 `87bac7a6…`，回滚副本在 `/opt/cubesandbox-s33f-predeploy-backup-exec-v1`，effective privileged 开关为 `false`。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3 全部 `DONE`。S3.3f 补齐非 TTY exec 的 capability/rlimit/NNP 传输与不可表达字段 fail-closed；组合回归覆盖 16 个成功容器、3 类 StartError、2 类 no-record、8 个 Cube sandbox/tombstone 和 21 项支持矩阵。同一 reviewer 最终给出 `APPROVE S3.3f DONE`。

## 未完成

S3.4a～S3.4d 尚未完成。当前需诊断 CPU、memory、swap、PIDs、hugepages、ephemeral-storage 在 kubelet/containerd、Host VM cgroup 与 Guest per-container cgroup 的实际输入和职责；随后实现 Guest 限制、Host Pod VM 包络及压力回归。S3.3 的 TTY/stdin、Host device/GPU 和二期安全字段边界保持不变。

## 验证

S3.3f 构建 `inv-984fnr0n8h`、构建审计 `inv-b84fx5ght7`、部署 `inv-384g480rcx`、部署审计 `inv-884ga1gc5e`、正式 E2E `inv-v84gjpgj7k` 和独立审计 `inv-884huw00ab` 均为 `SUCCESS`。核心证据目录为 `/data/cubelet/s3.3-evidence/s33f-20260901T075735Z-1024831`；lease `524→532`，14 类集合在 `after-off`、`after-on` 和最终 `cleanup` 均恢复精确基线。终审结束时三项服务 active、节点 Ready/无 DiskPressure，Cube Pod、Shim、VM、active lease 和 runtime resource 均为 0。完整摘要见 `evidence/s3.3/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 处于 `VALIDATING`：Host/Guest 资源分层、in-place update 和非 CPU/内存资源职责必须由 S3.4a 原始证据决定，不能先写死实现。只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

执行 S3.4a：先只读审计 CubeShim/Agent 现有 Linux resources 与 Task Update 转换，再由同一 reviewer 审核云端探针。探针需用 runc/Cube 对照覆盖 QoS、request/limit、init/restartable sidecar/app，保存 raw Pod/CRI/ctr OCI、Host cgroup、Guest cgroup 和清理基线；结论更新 `K8S-OQ-014`～`K8S-OQ-016` 后才能进入 S3.4b。
