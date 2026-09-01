# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.3f `IN_PROGRESS`：S3.3e privileged 节点开关与 Pod 请求双门禁已经完成实现、云端构建、Kubernetes/Guest 正反例和独立审计；当前进入 S3.3 安全组合回归与首版支持矩阵冻结。

## 基线

最后一项已验证实现 commit 为 `d594a7faf2b3e7a8f8179745e2c971d0b4cb4e1b`，完整 tree 为 `03b777d92c390e6871e726c71f29f5622c00ca3c`；S3.3e 证据与复现脚本提交为 `ef02c127490b90af4b52619decff3ae63be68813`。正式 E2E 与独立审计脚本 SHA-256 分别为 `31d92bde92677d5121f60925b2ab3ca2d88b09c5e0d3b75a1c521710add90b1f` 和 `1037cfd0f16a8d6f80f57aeab082a70fb6ae7f6fbeb7217c9c4432a7d4af11e7`。live Shim 为 `84c27649…`，Agent ext4 为 `87bac7a6…`；回滚副本位于 `/opt/cubesandbox-s33e-predeploy-backup-v1`，节点开关已恢复为 `false`。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a～S3.2d、S3.3a～S3.3e 均为 `DONE`。S3.3e 增加默认关闭且严格解析的 `CUBE_ALLOW_PRIVILEGED` 节点开关，要求 Pod privileged 请求产生唯一 canonical all-devices OCI marker，并把提权限制在 Guest。Host `.linux.devices`、直接或解析到 `/dev` 的 bind source 均 fail-closed；Agent 保留 wildcard major/minor。开关关闭/开启、普通/privileged、Host `/dev` 负例、六次活动资源精确零基线、live 制品哈希和开关恢复都已由独立审计重算；同一 reviewer 最终给出 `APPROVE S3.3e DONE`。

## 未完成

S3.3f、S3.4 尚未完成。S3.3f 需要顺序重放 S3.3b～S3.3e 的组合安全矩阵并冻结支持/拒绝范围；TTY/stdin 仍可不支持。CSI、动态制备、CBS/CFS/COSFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 仍未验证；static local 只是 runtime 语义基线，不是生产存储方案。

## 验证

S3.3e 部署 `inv-684bwgg03r`、正式 E2E `inv-084cdrgc1k` 和独立审计 `inv-384cpa0n8v` 均为 `SUCCESS`。核心证据目录为 `/data/cubelet/s3.3-evidence/s33e-final-20260901T053443Z-806800`；构建与部署证据分别为 `/data/cubelet/s3.3-evidence/s3.3e-build-v4-20260901T051239Z` 和 `/data/cubelet/s3.3-evidence/s3.3e-deploy-20260901T051825Z`。目标 Guest 为 cgroup v2，无法读取 v1 `devices.list`，因此 Guest device rule E2E 明确标为不可观察；canonical OCI marker 与 Agent wildcard 转换由云端定向测试 2/2 补足，不宣称超出证据的覆盖。审计结束时 containerd、kubelet、runtime-resource service active，节点 Ready/无 DiskPressure，Cube Pod、Shim、VM、active lease 和 runtime resource 均为 0。完整摘要见 `evidence/s3.3/README.md`。

## 阻塞

无外部阻塞。S3.3e 已关闭 privileged 双门禁与 Host `/dev` fail-closed 证据。cgroup v2 不暴露 v1 `devices.list` 是已记录的可观测限制，不阻塞 S3.3f；S3.3f 不得把 Agent 定向测试表述为 Guest device rule 的直接 E2E 观察。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.3f：先根据 S3.3b～S3.3e 已固定的字段与失败语义设计最小但覆盖交叉影响的组合矩阵，绑定不可变 image、脚本 SHA、live runtime 哈希和节点基线；同一 reviewer 批准脚本后，在自管节点顺序重放身份/组、capabilities、RO/RW rootfs、NNP/seccomp、privileged 开关及 Host `/dev` 负例。验收必须从原始 Pod/CRI/OCI/Guest 证据复算，比较每轮 lease 与活动资源精确基线，生成支持/拒绝/二期范围矩阵，再由同一 reviewer 给出 `APPROVE S3.3f DONE`。
