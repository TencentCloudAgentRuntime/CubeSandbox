# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4b `IN_PROGRESS`：S3.4a 已获 `APPROVE S3.4a DONE`；Guest per-container cgroup 设计及 S3.4b.1～S3.4b.3 实现单元均获同一 reviewer 批准。当前执行 S3.4b.4 云端资源、压力、故障、兼容矩阵与独立审计。

## 基线

最后一项已验证实现 commit 为 `8784815628adb70573673156dbfcee855766ef20`，tree 为 `7316bafdcf5fd573b10c9ce42c0cb4f0573b78da`。该单元尚未部署，Agent 未广告 resources-v2 capability，中间态始终 fail-closed。V15 source SHA-256 为 `d4400132…`，containerd trace/helper 为 `88476ece…`/`242a68a8…`；live 原始 containerd 为 `15e00263…`，CubeShim 为 `3c715652…`，Agent ext4 为 `87bac7a6…`。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a 全部 `DONE`。S3.4b 设计、S3.4b.1 Shim/Protocol、S3.4b.2 Agent transaction 和 S3.4b.3 fail-stop/PendingCreate 已获同一 reviewer 批准。Agent 已实现严格 V2 解码、presence/partial merge、cgroup v2 transaction、rollback/undo replay 与 degraded 门禁，以及 create/storage/rootfs/process/cgroup/FD 的显式所有权和幂等可重试清理。

## 未完成

S3.4b.4 与 S3.4c～S3.4d 尚未完成。resources-v2 capability 广告、固定 SHA 云端部署和正式矩阵仍未完成。V15 的非默认 period、shares、limit-only swap、NoSwap、reservation、显式 swap、cpuset、PIDs、hugepage、unified、transaction/degraded 与 create cleanup 仍待真实 Guest 验收。

## 验证

S3.4b.3 的 `cargo check -p cube-agent`、`cargo test -p cube-agent --no-run`、格式和 diff 检查通过；rustjail 全量 128/129，唯一失败为受限本机 `container::tests::test_set_stdio_permissions` 的 `fchown` EINVAL；跳过该宿主机特定用例后的 128/128 稳定集连续三轮通过；Agent degraded/update/pending-create/shared-storage/tombstone 专项通过。S3.4a V15 构建、正式诊断和独立审计仍为 `SUCCESS`，完整摘要见 `evidence/s3.4/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 继续 `VALIDATING`，但 V15 已给出可用于实现的父层权威值和精确缺口；只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

执行 S3.4b.4：广告并握手 resources-v2 capability；构建、经指定私有 COS 投递并在项目 CVM 部署固定 SHA 的 Shim/Agent；完成 runc/Cube create/update 数值、CPU/内存/PIDs/hugepage 压力、transaction/degraded/create-cleanup 失败注入、legacy/unsupported 兼容路径、survivor 与 exact baseline 矩阵；保存证据并由同一 reviewer 独立审计。S3.4b 获批前不得开始 S3.4c。
