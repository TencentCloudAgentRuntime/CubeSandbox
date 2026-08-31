# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.1 `IN_PROGRESS`：S3.1a 输入诊断、S3.1b 可写 Volume 通道和 S3.1c 投射卷与 subPath 均已获同一 reviewer `APPROVE`；当前执行 S3.1d 回归与支持矩阵。

## 基线

最后一项已验证实现 commit 为 `20881f71dd21c48d83f32adf1d01a2257472a8ec`，完整 tree 为 `050287f6d68a736f680c3d81e3c0a63e644e28bf`。最终 shim SHA-256 为 `4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14`，`cube-agent.ext4` 仍为 `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`，RuntimeResource harness SHA-256 为 `7a525e8541eb774e6f80788819873c7c80fdf812eeb5b1f9d99fed20dcaf8b82`。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1c 均为 `DONE`。S3.1c 已证明 `cubeVolumes cache=none` 可传播 ConfigMap、Secret、projected 与 downwardAPI 的 atomic-writer 更新；多容器同步可见，subPath 保持旧值和旧 inode，Sandbox/shim/VM/Task generation/mount ID 稳定，删除后 active lease 为 0、tombstone 精确增加 1。同一 reviewer 最终 `APPROVE`。

## 未完成

S3.1d 尚未完成全量回归和支持矩阵，S3.1 整体尚未关闭。`K8S-OQ-011` 与 `K8S-OQ-007` 均已转为 `DECIDED`。

## 验证

S3.1c 终验 `inv-a83th50gfh` 为 `SUCCESS`；脚本 SHA-256 为 `2bcda47e00617640956ab4e3e9bfc63b02f9b6d23057a56cb6d529ffa30e4aaa`，云端证据目录为 `/data/cubelet/s3.1-evidence/s3.1c-projected-20260831T195803Z`。同一 reviewer 对脚本修订和最终证据均为 `APPROVE`。S3.1b 的构建、终验和独立审计继续有效；完整摘要见 `evidence/s3.1/README.md`。

## 阻塞

无外部阻塞。S3.1d 只需组合复现已通过的 Volume 主路径并冻结支持矩阵。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.1d：组合复现 S3.1b 可写卷、失败回滚与 S3.1c 投射卷动态更新；核对 Pod UID/IP、Sandbox、shim、VM、Task generation、mount 和删除基线；形成首版 Volume 支持/限制矩阵。同一 reviewer `APPROVE` 后关闭 S3.1，再进入 S3.2。
