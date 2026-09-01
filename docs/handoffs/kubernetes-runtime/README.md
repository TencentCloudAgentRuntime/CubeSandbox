# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4b `IN_PROGRESS`：S3.4a 已获 `APPROVE S3.4a DONE`；Guest per-container cgroup 设计已获 `APPROVE S3.4b DESIGN`；S3.4b.1 mirrored proto、Shim raw 校验/V2 发包、capability gate 和 devices update fail-close 已获同一 reviewer `APPROVE S3.4b SHIM/PROTOCOL UNIT`。当前执行 S3.4b.2 Agent strict decode 与 cgroup v2 transaction。

## 基线

最后一项已验证实现 commit 为 `6a07ff69ec02d4d77203e1f9b3021713110e2d73`，tree 为 `22e9ae382ff3460d867b21d83d4387d24e92edd8`。该单元尚未部署，Agent 未广告 resources-v2 capability，中间态始终 fail-closed。V15 source SHA-256 为 `d4400132…`，containerd trace/helper 为 `88476ece…`/`242a68a8…`；live 原始 containerd 为 `15e00263…`，CubeShim 为 `3c715652…`，Agent ext4 为 `87bac7a6…`。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a 全部 `DONE`。S3.4b 设计和 S3.4b.1 Shim/Protocol 单元完成并获同一 reviewer 批准；双侧 tag-8 golden wire 与 Shim/Agent 编译检查通过。

## 未完成

S3.4b.2～S3.4b.4 与 S3.4c～S3.4d 尚未完成。Agent 仍使用旧 scalar/presence 转换和 cgroups-rs 写入器，因此新 capability 尚未广告、代码也未部署。V15 的非默认 period、shares 映射、limit-only swap presence、NoSwap 无损传输、reservation、显式 swap、cpuset、PIDs、hugepage、unified、transaction rollback/degraded 和 PendingCreate cleanup 仍待实现与云端验收。

## 验证

S3.4a V15 构建 `inv-984uubgkt5`、稳定预检 `inv-b84uvagqkj`、正式诊断 `inv-084uvpg3h5` 和独立审计 `inv-384uxu0pj7` 均为 `SUCCESS`。核心证据目录为 `/data/cubelet/s3.4-evidence/s34a-20260901T145751Z-2537408`；覆盖 6 个高层 Pod、17 个成功低层 Task、1 个预期 create reject、2 个 invalid-unified 和 20 份 trace protobuf。raw create/update 与 actual Runtime identity 均验证，正式脚本和审计均确认 `cleanup=exact`；原始 containerd 恢复、三项服务 active、Node healthy且测试对象无残留。完整摘要见 `evidence/s3.4/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 继续 `VALIDATING`，但 V15 已给出可用于实现的父层权威值和精确缺口；只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

实现 S3.4b.2：Agent 严格复核 envelope/canonical JSON，补齐 presence 模型与逐字段 merge，并以独立 cgroup v2 planner/transaction 完成 preflight、journal、确定顺序写入、readback 与 rollback。通过单测和同一 reviewer 后进入 S3.4b.3 degraded/PendingCreate；S3.4b 获批前不得开始 S3.4c。
