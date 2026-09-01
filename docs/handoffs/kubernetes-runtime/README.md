# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.3d `IN_PROGRESS`：S3.3c capabilities 与只读 rootfs 已完成正式云验、两个独立审计和 legacy race 回归，并获同一 reviewer `APPROVE S3.3c DONE`；当前修复 NNP 静默降级并固化 seccomp。

## 基线

最后一项已验证实现 commit 为 `c55b759e8d0f836164b092fab20739acceb42836`，完整 tree 为 `3cd344f557471635e23b935175032dc35f717302`。S3.3c 负例/正例脚本 SHA-256 分别为 `bfa8e6c7040108eb35d32c8acad094031debf7e5ef69284214a62284fa18399b` 和 `6d3a5f52260e5d591c9cddb2eb3f9e861de1a798c67ef233074a3aaacce655d4`。实际 E2E runtime 固定 Shim `51b54472…`、Agent ext4 `0b87e424…`；实现提交已包含完整源代码与云验脚本。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a～S3.2d、S3.3a～S3.3c 均为 `DONE`。S3.3c 固化 OCI capability 五集合、非法名称 host fail-closed、ambient 错误传播和 rootfs readonly/write-layer 语义；两轮 18 Pod/26 container/9 Cube sandbox 覆盖五类 mask、CAP 40、RO/RW/emptyDir 与非 TTY exec，所有活动资源恢复精确基线。legacy 回归另通过 14 个 BPF 产物和 324 项 Cubebox race tests；同一 reviewer 最终明确 `APPROVE S3.3c DONE`。

## 未完成

S3.3d～S3.3f、S3.4 尚未完成。S3.3d 修复 NNP 并验证 seccomp，S3.3e 实现 privileged 双门禁，S3.3f 组合回归；TTY/stdin 仍可不支持。CSI、动态制备、CBS/CFS/COSFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 仍未验证；static local 只是 runtime 语义基线，不是生产存储方案。

## 验证

S3.3c 负例 `inv-b845t9grgt`、正式正例 `inv-6846wbgtiv`、总体只读审计 `inv-6847cm06pi`、legacy race 回归 `inv-084814gvgg` 和 legacy 独立审计 `inv-a8487g0n1w` 均为 `SUCCESS`。核心证据目录为 `/data/cubelet/s3.3-evidence/s3.3c-capabilities-rootfs-20260901T022736Z`；审计复算 18 个 Pod UID、26 个 container ID、九个 Sandbox、五类 capability mask、RO/RW/emptyDir、lease `479→488` 与所有检查点。legacy 证据目录为 `/data/cubelet/s1.4-evidence/legacy-cubebox-tests-20260901T030441Z-554186`，独立复算 14 个 BPF 双 SHA 与 324/324 项 JSONL test。同一 reviewer 最终 `APPROVE S3.3c DONE`；完整摘要见 `evidence/s3.3/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-013` 已记录 CubeShim 强制清零 NNP 的实现缺口，必须在 S3.3d 通过兼容实现和 Guest 正反用例关闭；在此之前不能声明 NNP 支持。S3.3 继续从 CRI/OCI/Guest 三层取证，privileged 保持节点开关与 Pod 请求双门禁。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.3d：先冻结 CubeShim/Agent protobuf 对 `noNewPrivileges` 与 seccomp 的兼容契约，并重放 S3.3a 的 host true/Guest false 基线；再移除 Shim 强制清零，完成 NNP false/true 正反例、RuntimeDefault seccomp 过滤行为、失败清理和独立审计，关闭 `K8S-OQ-013`。随后按 S3.3e privileged 双门禁、S3.3f 回归矩阵顺序执行。
