# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.1 `IN_PROGRESS`：S3.1a 输入与现状诊断已获同一 reviewer `APPROVE`；当前执行 S3.1b 独立 Pod Volume share。

## 基线

最后一项已验证运行时实现/验收 commit 仍为 `495ac4ca2d0f03fd6ba709ae528829db71f25453`，完整 tree 为 `d6b370860393aa141844113eda9f89aa8b075b33`；S3.1a 诊断脚本 commit 为 `e0c85aab`。最终 shim SHA-256 为 `0b89ae6d33bbe5cb5e10a02ba490fc4d9aae56d768863c30de7712bac242a4d5`，`cube-agent.ext4` SHA-256 为 `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`，RuntimeResource harness SHA-256 为 `26cb87a0f1adb2b2a8f6f0125d4d9eb39661949030d5b8ecda2af53bf37f0ade`。

## 已完成

S0、S1 和 S2.1～S2.4 均为 `DONE`。S3.1a 已用 runc 对照冻结 11 个标准 OCI bind 输入：Cube 启动投射正确，但 disk/memory emptyDir 均因 `cubeShared ro` 返回 EROFS，投射卷 194 秒内不更新；删除后两个 kubelet Pod 目录、29 条相关 host mount 和 19 个 shared target 全部清除，active lease 为 0、tombstone 精确增加 1。同一 reviewer 最终 `APPROVE`。

## 未完成

S3.1b 尚未实现独立 Pod Volume share；S3.1c 尚未在新通道上复测 ConfigMap、Secret、projected、downwardAPI、subPath 与动态更新；S3.1d 尚未完成回归和支持矩阵。可写 bind 方案已冻结但仍处于 `K8S-OQ-011` 的实现验证阶段。

## 验证

S3.1a `inv-a83peh0hec` 为 `SUCCESS`；脚本 SHA-256 为 `837a15dec76ed973875dd0fe260344fb3ca523220f6018d881d3c0e1c87d675f`，云端证据目录为 `/data/cubelet/s3.1-evidence/s3.1a-diagnostic-20260831T173842Z`。同一 reviewer 对脚本与云证据均为 `APPROVE`。完整摘要见 `evidence/s3.1/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-011` 已进入独立 Volume share 实现验证；`K8S-OQ-007` 的动态投射更新不作为首版阻塞，但必须在 S3.1c 明确支持状态。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

先复现 `evidence/s3.1/README.md` 的 `inv-a83peh0hec` 摘要。S3.1b 保留现有只读 rootfs share，新增 Pod 级 Volume share，把 kubelet 标准 bind source 导出到新通道并保留 OCI 逐 mount `ro/rw`；覆盖创建失败、Task 删除、Pod 删除和 mount generation 清理。完成后由同一 reviewer 验收，再进入 S3.1c。
