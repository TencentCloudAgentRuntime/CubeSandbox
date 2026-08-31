# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S2.4 `IN_PROGRESS`：S2.3 Pod namespace 与加固 PID holder 已完成并获同一 reviewer `APPROVE`；当前开始 Sidecar 与 Pod 生命周期矩阵。

## 基线

最后一项已验证实现/验收 commit 为 `a50425d308cd0c31b72e716d7e92bc7e945bcf3c`，完整 tree 为 `7d4eb405bcd23aef1ad65ab1992bac61bdcbcd39`。S2.3 最终 shim SHA-256 为 `0b89ae6d33bbe5cb5e10a02ba490fc4d9aae56d768863c30de7712bac242a4d5`，`cube-agent.ext4` SHA-256 为 `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`。

## 已完成

S0、S1.1～S1.4 和 S2.1～S2.3 均为 `DONE`。S2.3 已证明默认与共享 PID 两种 Pod namespace 语义、加固 PID 1、单容器替换后 namespace/holder/survivor 稳定，以及三类 host namespace 在资源分配前拒绝；全部用例恢复全量基线。同一 reviewer 最终 `APPROVE`。

## 未完成

S2.4 尚未验证 Kubernetes 原生 sidecar 启停顺序、ephemeral container 动态加入、startup/readiness/liveness probe、lifecycle hook 与 graceful termination/TaskExit 时序。可写 `emptyDir` 问题仍归 S3.1。

## 验证

S2.3 严格构建 `inv-v83iix062d`、版本化部署 `inv-883iq5gvea` 与终验 `inv-a83j9u0q12` 均为 `SUCCESS`。终验脚本 SHA-256 为 `3e36361c1b1380d874093879c9323f0d2b9bb3210322ff4530a12e03359fb039`；active lease 归零、tombstone 增量为 2，同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s2.3/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-010` 目标 S5；`K8S-OQ-011` 目标 S3.1，均不阻塞 S2.4。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

先复现 `evidence/s2.3/README.md` 的 `inv-a83j9u0q12` 摘要。随后盘点 Kubernetes 1.36 原生 sidecar、ephemeral container、probe、hook 和 graceful termination 在现有 CRI/Sandbox/Task 链路中的实际行为；先建立不改代码的诊断矩阵，再按缺口实现并逐案保持 Pod UID/IP、Sandbox/VM、shim、survivor 与删除基线。完成后交同一 reviewer。
