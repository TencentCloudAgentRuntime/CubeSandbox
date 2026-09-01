# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.3c `IN_PROGRESS`：S3.3b UID/GID 与组已完成正式云验、独立审计并获同一 reviewer `APPROVE`；当前固化 capabilities 与只读 rootfs。

## 基线

最后一项已验证实现 commit 为 `d6c16e6b55e4b51249f2619c11e31c3750ae4196`，完整 tree 为 `75482378d7ba2732e6172940db043555d71174b5`。S3.3b 云验脚本 SHA-256 为 `0fc2adf4e46687c493b843a8dc8689656e6ee9e81a1ff7c50e99bc0b84f1c619`；独立审计 SHA-256 为 `309b1364581af862fe9fb73ee0d8d5ab80af6f589c7f054135cf3ac89f405421`。实际 E2E runtime 固定实现基线 `83902212`、Shim `4c33aa39…` 和 Agent `b1f5d685…`；新 source identity helper 由 `inv-9841kq036r` 定向单测覆盖。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a～S3.2d、S3.3a～S3.3b 均为 `DONE`。S3.3b 固化 create/exec 数值 UID/GID 和 additionalGids 原样透传，并单独覆盖 exec username；两轮 runc/Cube Merge/Strict、fsGroup emptyDir、classic init、restartable sidecar、PodStatus 与非 TTY exec 均等价。14 个 Pod UID、20 个正例 container ID 和七个 Cube Sandbox 全部唯一；七个 Sandbox 各一条 inactive lease/单 tombstone，所有检查点与实时状态精确恢复基线，同一 reviewer 最终明确 `APPROVE`。

## 未完成

S3.3c～S3.3f、S3.4 尚未完成。S3.3c 固化 capabilities/只读 rootfs，S3.3d 修复 NNP 并验证 seccomp，S3.3e 实现 privileged 双门禁，S3.3f 组合回归；TTY/stdin 仍可不支持。CSI、动态制备、CBS/CFS/COSFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 仍未验证；static local 只是 runtime 语义基线，不是生产存储方案。

## 验证

S3.3b 最终验收 `inv-384315g7di` 和独立只读审计 `inv-a843e8g0wv` 均为 `SUCCESS`；证据目录为 `/data/cubelet/s3.3-evidence/s3.3b-identity-groups-20260901T001403Z`。审计从 PodSpec、原始 CRI/ctr JSON/JSONL、PodStatus、Guest observation/log、完整 image passwd/group 和完整 lease inventory 复算 14 个 UID、20 个 container ID、七个 Sandbox 与 lease `466→473`；round1、round2、negative、final、EXIT 以及审计时实时状态均精确恢复基线，active lease 与固定残留均为 0。同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s3.3/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-013` 已记录 CubeShim 强制清零 NNP 的实现缺口，必须在 S3.3d 通过兼容实现和 Guest 正反用例关闭；在此之前不能声明 NNP 支持。S3.3 继续从 CRI/OCI/Guest 三层取证，privileged 保持节点开关与 Pod 请求双门禁。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.3c：先冻结 capability add/drop 的 OCI 输入与 Guest effective/permitted/inheritable/bounding/ambient mask，以及 readonly rootfs 的 OCI flag、Guest mount 和写失败语义；再补 `drop ALL`、选择性 add、边界 capability、只读/可写正反例和重复清理。完成独立云验与同一 reviewer `APPROVE` 后，按 S3.3d NNP/seccomp、S3.3e privileged 双门禁、S3.3f 回归矩阵顺序执行。
