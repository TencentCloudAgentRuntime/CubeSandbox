# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4b `IN_PROGRESS`：S3.4a V15 父 resource cgroup、`runtime` process leaf、实际 RuntimeClass/containerd runtime identity 和独立审计已闭环，同一 reviewer 已给出 `APPROVE S3.4a DONE`；Guest per-container cgroup 的协议、presence、字段矩阵、事务与失败语义已冻结，同一 reviewer 已给出 `APPROVE S3.4b DESIGN`，当前进入实现。

## 基线

最后一项已验证实现 commit 为 `96b5a64fedd1f58b6e4834466755cf175f92cddd`，tree 为 `7eabf7ef5a2ba0d3a006bf845428eaab6c0028d4`。V15 source SHA-256 为 `d4400132…`，containerd trace/helper 为 `88476ece…`/`242a68a8…`；live 原始 containerd 为 `15e00263…`，CubeShim 为 `3c715652…`，Agent ext4 为 `87bac7a6…`。私有 COS 输入对象为 `kubernetes-runtime/s3.4a/source/cubesandbox-s34a-source-v14-d4400132.tar.gz`。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a 全部 `DONE`。S3.4a V15 正式矩阵、raw create/update、Runtime identity、父/子 cgroup、Host 拓扑、terminated classic init、ephemeral-storage 和 exact cleanup 均已通过；同一 reviewer 最终确认 `APPROVE S3.4a DONE`。

## 未完成

S3.4b 正在进行设计冻结，S3.4c～S3.4d 尚未开始。V15 已确认 CPU quota 与 `memory.max` 的 Guest create/update 数值链可用；period 输入和结果始终为默认 `100000`，尚未独立证明。shares 使用的旧线性 weight 映射与当前 runc/cgroups v3 不兼容，memory-limit-only create 还会把未指定 swap 隐式写为 `0`；Kubernetes NoSwap 的 observable `0` 同样来自该副作用，OCI unified `memory.swap.max=0` 并未进入 Agent。S3.4b 应连同非默认 period、NoSwap 无损传输/回归、reservation update、显式 swap、cpuset、PIDs、hugepage、unified 和 accepted-unapplied fail-close 一起修复。S3.3 的 TTY/stdin、Host device/GPU 和二期安全字段边界保持不变。

## 验证

S3.4a V15 构建 `inv-984uubgkt5`、稳定预检 `inv-b84uvagqkj`、正式诊断 `inv-084uvpg3h5` 和独立审计 `inv-384uxu0pj7` 均为 `SUCCESS`。核心证据目录为 `/data/cubelet/s3.4-evidence/s34a-20260901T145751Z-2537408`；覆盖 6 个高层 Pod、17 个成功低层 Task、1 个预期 create reject、2 个 invalid-unified 和 20 份 trace protobuf。raw create/update 与 actual Runtime identity 均验证，正式脚本和审计均确认 `cleanup=exact`；原始 containerd 恢复、三项服务 active、Node healthy且测试对象无残留。完整摘要见 `evidence/s3.4/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 继续 `VALIDATING`，但 V15 已给出可用于实现的父层权威值和精确缺口；只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

按已批准的 [`s3.4b-design.md`](evidence/s3.4/s3.4b-design.md) 实现：先完成 mirrored proto、Shim raw JSON/capability/V2 发包与 Agent strict decode/presence，再完成 cgroup v2 planner/transaction/merge/degraded 状态及 PendingCreate cleanup。保持 quota 与 `memory.max` 数值更新不回退，增加非默认 period，统一 shares→weight 到当前 containerd/cgroups v3 语义，并修复 limit-only swap presence、无损处理/白名单 unified、reservation、显式 swap、cpuset、PIDs 与 hugepage；本地测试和同一 reviewer 批准后再做云端矩阵，S3.4b 获批前不得开始 S3.4c。
