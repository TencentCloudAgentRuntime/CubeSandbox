# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.3e `IN_PROGRESS`：S3.3d 已完成 NNP 与 RuntimeDefault seccomp 的实现、云端全量测试、两轮 Kubernetes/Guest E2E 和独立审计；当前进入 privileged 节点开关与 Pod 请求双门禁。

## 基线

最后一项已验证实现 commit 为 `5a8512456b46ab31a28bc0fc11500562c0385499`，完整 tree 为 `64f5b1852eac39a7887966abcce143a090816806`。S3.3d 正例与独立审计脚本 SHA-256 分别为 `79aba88c3a46e4f7f6d0d3834f44ddf6152bc779a9a4503bdc4d8f055b04658a` 和 `4baeaf7699a1f721d88ad74d77d21c44072d053e712a8f8ed787a87b9dbb3bd6`。实际 E2E runtime 固定 Shim `60ba8906…`、Agent ext4 `0b87e424…`；旧 Shim 位于 `/opt/cubesandbox-s33d-predeploy-backup-v1`。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a～S3.2d、S3.3a～S3.3d 均为 `DONE`。S3.3d 移除 Shim 对 NNP 的强制清零，保留 Kubernetes RuntimeDefault seccomp 子集，并对当前 protobuf 无法无损表达的字段 fail-closed。两轮 8 Pod/4 Cube sandbox 的 runc/Cube 对照证明 Guest NNP `0/1`、seccomp mode `0/2` 和 `unshare` 允许/阻断一致；lease `488→492`，active lease 0，所有活动资源恢复精确基线。独立审计从原始 CRI/ctr、Pod/UID、Guest、sandbox/lease 和 live state 重新计算并通过；同一 reviewer 最终给出 `APPROVE S3.3d DONE`。

## 未完成

S3.3e～S3.3f、S3.4 尚未完成。S3.3e 实现 privileged 双门禁，S3.3f 组合回归；TTY/stdin 仍可不支持。CSI、动态制备、CBS/CFS/COSFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 仍未验证；static local 只是 runtime 语义基线，不是生产存储方案。

## 验证

S3.3d 最终 Shim 构建 `inv-b8497x0qge`、Agent 全量重放 `inv-98492wgis7`、部署 `inv-6849ef00t9`、正式 E2E `inv-b849phgapi` 和独立审计 `inv-3849tjgnmx` 均为 `SUCCESS`。核心证据目录为 `/data/cubelet/s3.3-evidence/s3.3d-nnp-seccomp-20260901T040243Z`；正式脚本完成两轮 8 Pod/4 Sandbox、NNP/seccomp/unshare 正反例、4 条 inactive tombstone、lease `488→492` 和三次精确基线。首次 `inv-0849f6g6w5` 仅在 Pod 创建前被 DiskPressure 门禁拦截，cleanup 成功；清理 8 个中间 build 目录后 Node 恢复健康，最终 `inv-8849wngpex` 证明测试 Pod 不存在、服务 active、Ready=true、DiskPressure=false。完整摘要见 `evidence/s3.3/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-013` 已由 S3.3d 关闭；NNP 与当前 Kubernetes RuntimeDefault seccomp 子集已通过 runc/Cube 对照和独立审计。S3.3e 仍须冻结 privileged 的原始 CRI/OCI/Guest 基线，实现节点开关与 Pod 请求双门禁，并证明普通 Pod 不提权且不自动透传 Host device/path。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.3e：先冻结 privileged Pod 在 kubelet/CRI/OCI、CubeShim protobuf 和 Guest 的当前输入/行为，确定节点开关的配置归属与默认关闭语义；再实现“节点允许且 Pod 请求”双门禁，完成关闭拒绝、开启提权、普通 Pod 不提权、Host device/path 不透传、失败清理和独立审计。随后执行 S3.3f 安全组合回归与支持矩阵。
