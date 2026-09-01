# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4b `IN_PROGRESS`：S3.4a 已获 `APPROVE S3.4a DONE`；Guest per-container cgroup 设计已获 `APPROVE S3.4b DESIGN`；S3.4b.1 Shim/Protocol 已获 `APPROVE S3.4b SHIM/PROTOCOL UNIT`，S3.4b.2 Agent decode/controller transaction 已获同一 reviewer `APPROVE S3.4b.2`。当前执行 S3.4b.3 degraded/PendingCreate。

## 基线

最后一项已验证实现 commit 为 `8e54a209521070d007e10919f807cbfdc570c4a0`，tree 为 `50c572b16af7e0e70eb5321377b66429f446a3c2`。该单元尚未部署，Agent 未广告 resources-v2 capability，中间态始终 fail-closed。V15 source SHA-256 为 `d4400132…`，containerd trace/helper 为 `88476ece…`/`242a68a8…`；live 原始 containerd 为 `15e00263…`，CubeShim 为 `3c715652…`，Agent ext4 为 `87bac7a6…`。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a 全部 `DONE`。S3.4b 设计、S3.4b.1 Shim/Protocol 和 S3.4b.2 Agent transaction 已获同一 reviewer 批准。Agent 已实现严格 V2 二次解码、presence/partial merge、cgroup v2 planner/journal/readback/rollback/replay、区间式 cpuset、空值恢复及 cgroup-device eBPF。

## 未完成

S3.4b.3～S3.4b.4 与 S3.4c～S3.4d 尚未完成。ResourceDegraded 的 RPC 门禁/replay-first、PendingCreate owner/可重试 cleanup、capability 广告和云端正式矩阵仍未完成，因此代码尚未部署。V15 的非默认 period、shares、limit-only swap、NoSwap、reservation、显式 swap、cpuset、PIDs、hugepage、unified、transaction/degraded 与 create cleanup 仍待真实 Guest 验收。

## 验证

S3.4b.2 本地资源专项 22/22、device eBPF 3/3、`cargo check -p cube-agent` 和 `git diff --check` 通过；rustjail 全量 101/102，唯一失败为受限本机 `fchown` EINVAL；Agent 可运行用例 85 项通过，其余为 mount/netlink/chown/cgroup 权限限制。S3.4a V15 构建、正式诊断和独立审计仍为 `SUCCESS`，完整摘要见 `evidence/s3.4/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 继续 `VALIDATING`，但 V15 已给出可用于实现的父层权威值和精确缺口；只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

实现 S3.4b.3：把 transaction `Degraded`/undo replay 接入 container 与 RPC fail-stop 状态机；引入 `PendingCreate` owner，覆盖 storage/bundle/process/resource cgroup 的幂等、可重试 cleanup；完成失败注入单测并由同一 reviewer 批准后进入 S3.4b.4。S3.4b 获批前不得开始 S3.4c。
