# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.1 `IN_PROGRESS`：S3.1a 输入诊断和 S3.1b 可写 Volume 通道均已获同一 reviewer `APPROVE`；当前执行 S3.1c 投射卷与 subPath。

## 基线

最后一项已验证运行时实现 commit 为 `5b504b5826c3224e33f85ea9a3761f68cdb972b1`，完整 tree 为 `60747aa08d1d9382fa74c43eb4cb6fa74f72f3ea`。最终 shim SHA-256 为 `4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14`，`cube-agent.ext4` 仍为 `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`，RuntimeResource harness SHA-256 为 `7a525e8541eb774e6f80788819873c7c80fdf812eeb5b1f9d99fed20dcaf8b82`。

## 已完成

S0、S1、S2.1～S2.4、S3.1a 和 S3.1b 均为 `DONE`。S3.1b 已增加独立 `cubeVolumes` share 和 mount-aware 生命周期；disk/memory emptyDir 跨 init/app/sidecar 双向读写、同源 `rw/ro`、只读 rootfs、direct CRI Task generation、失败创建回滚与删除全量基线均通过，active lease 为 0、tombstone 精确增加 2。同一 reviewer 最终 `APPROVE`。

## 未完成

S3.1c 尚未在新通道上复测 ConfigMap、Secret、projected、downwardAPI、subPath 与动态更新；S3.1d 尚未完成回归和支持矩阵。`K8S-OQ-011` 已由 S3.1b 验证并转为 `DECIDED`；`K8S-OQ-007` 仍待 S3.1c 决策。

## 验证

S3.1b 构建 `inv-a83rxbgg0g`、终验 `inv-a83sdvgumu` 和独立审计 `inv-883sh80mpp` 均为 `SUCCESS`；最终脚本 SHA-256 为 `1133a645267a37c479dc37d5e729e84f76fcdb3b7d63ed2fd6b173c058d2972e`，云端证据目录为 `/data/cubelet/s3.1-evidence/s3.1b-writable-20260831T192027Z`。同一 reviewer 对实现、脚本和最终证据均为 `APPROVE`。完整摘要见 `evidence/s3.1/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-007` 的动态投射更新不作为首版阻塞，但必须在 S3.1c 明确支持状态。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

先复现 `evidence/s3.1/README.md` 的 `inv-883sh80mpp` 摘要。S3.1c 在已验证的 `cubeVolumes cache=none` 通道上覆盖 ConfigMap、Secret、projected、downwardAPI 的启动值、mode、atomic-writer symlink swap、动态更新延迟和 kubelet 已展开的 subPath；把支持结论写入 `K8S-OQ-007`。完成后由同一 reviewer 验收，再进入 S3.1d。
