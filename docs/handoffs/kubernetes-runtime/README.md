# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.3b `IN_PROGRESS`：S3.3a 输入与现状诊断已获同一 reviewer `APPROVE`；当前固化 UID/GID 与 supplemental groups。

## 基线

最后一项已验证实现 commit 为 `9380c163f1c299fdf184d41cccdb2b4a3894e51a`，完整 tree 为 `f261edbe1bcf0fabc273a794041ba0ea3d132a60`。S3.3a 诊断脚本 SHA-256 为 `d8ff768bd07a4f9bb1554ea223d1d74df39c68343815d0c5d1ac6d990bdb7682`；实际运行时仍使用实现基线 `83902212`、Shim `4c33aa39…` 和 Agent `b1f5d685…`。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a～S3.2d、S3.3a 均为 `DONE`。S3.3a 用八个不同 Pod UID、四个 Cube Sandbox 对照六项安全字段；UID/GID、supplemental groups、NET_RAW、readonly rootfs 和 RuntimeDefault seccomp 当前匹配，Cube NNP 从 host true 降为 Guest 0。四个 Sandbox 各产生且仅产生一条 inactive durable lease，删除后精确恢复基线，同一 reviewer 明确 `APPROVE`。

## 未完成

S3.3b～S3.3f、S3.4 尚未完成。S3.3b 固化 UID/GID/groups，S3.3c 固化 capabilities/只读 rootfs，S3.3d 修复 NNP 并验证 seccomp，S3.3e 实现 privileged 双门禁，S3.3f 组合回归；TTY/stdin 仍可不支持。CSI、动态制备、CBS/CFS/COSFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 仍未验证；static local 只是 runtime 语义基线，不是生产存储方案。

## 验证

S3.3a 最终诊断 `inv-9840smg1q7` 和独立只读审计 `inv-a840xpgpsu` 均为 `SUCCESS`；证据目录为 `/data/cubelet/s3.3-evidence/s3.3a-security-context-diagnostic-20260831T225851Z`。审计从原始 CRI/ctr JSON 复算输入，绑定八个 Pod 身份，核对 Guest init/log、六项矩阵、lease `431→435`、四条唯一 inactive tombstone、精确基线和实时零残留；最终 active lease 与固定残留均为 0。同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s3.3/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-013` 已记录 CubeShim 强制清零 NNP 的实现缺口，必须在 S3.3d 通过兼容实现和 Guest 正反用例关闭；在此之前不能声明 NNP 支持。S3.3 继续从 CRI/OCI/Guest 三层取证，privileged 保持节点开关与 Pod 请求双门禁。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.3b：在 S3.3a 当前匹配结果上固化 UID/GID 与 supplemental groups 的实现契约、正反边界和重复清理；完成独立云验与同一 reviewer `APPROVE` 后进入 S3.3c。后续按 S3.3c capabilities/只读 rootfs、S3.3d NNP/seccomp、S3.3e privileged 双门禁、S3.3f 回归矩阵顺序执行。
