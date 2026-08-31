# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.1 `IN_PROGRESS`：S2.4 Sidecar 与 Pod 生命周期已完成并获同一 reviewer `APPROVE`；当前开始基础 Volume 诊断与实现。

## 基线

最后一项已验证实现/验收 commit 为 `495ac4ca2d0f03fd6ba709ae528829db71f25453`，完整 tree 为 `d6b370860393aa141844113eda9f89aa8b075b33`；其中 Cilium TAP vnet header 修复为 `df54800044b9dc0fcd764a19fa393ca4eb70f014`。最终 shim SHA-256 为 `0b89ae6d33bbe5cb5e10a02ba490fc4d9aae56d768863c30de7712bac242a4d5`，`cube-agent.ext4` SHA-256 为 `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`，RuntimeResource harness SHA-256 为 `26cb87a0f1adb2b2a8f6f0125d4d9eb39661949030d5b8ecda2af53bf37f0ade`。

## 已完成

S0、S1 和 S2.1～S2.4 均为 `DONE`。S2.4 已证明两个原生 sidecar 的顺序与定向重启、ephemeral container 动态加入/exit47/不重启、startup/readiness/liveness probe、PostStart/幂等 PreStop、优雅 exit0 与 4 秒 grace 后 SIGKILL137。单容器变化期间 survivor、Pod UID/IP、Sandbox、shim 与 VM 稳定；逐例恢复全量基线。同一 reviewer 最终 `APPROVE`。

## 未完成

S3.1 尚未盘点并实现 `emptyDir`、ConfigMap、Secret、projected、downwardAPI、subPath 和只读/可写 mount 语义。固定只读 virtio-fs share 下的可写 bind 是 `K8S-OQ-011`；尚无实现结论。

## 验证

S2.4 D1 `inv-383kh2g6w4`、D2 `inv-983kt80r3f`、D3 `inv-683nbagv5s`、D4 `inv-383nsc0was` 均为 `SUCCESS`。网络修复严格构建 `inv-983mvhgxik`、部署 `inv-683n14gk0q`、四方向复测 `inv-683n9h04ri` 均成功。每个成功 Sandbox 删除后 active lease 归零、tombstone 精确增加 1；同一 reviewer 逐阶段最终 `APPROVE`。完整摘要见 `evidence/s2.4/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-011` 是 S3.1 必须解决的可写 volume 问题；`K8S-OQ-010` 和 ephemeral TARGET PID 的 `K8S-OQ-012` 目标为 S5，不阻塞 S3.1 诊断。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

先复现 `evidence/s2.4/README.md` 的 `inv-383nsc0was` 摘要。随后只读盘点 kubelet 为基础 Volume 生成的 OCI mount/rootfs 输入，建立读写、跨容器、更新、subPath 与删除残留矩阵；先用诊断证据冻结 `K8S-OQ-011` 的最小实现边界，再改 Agent/Shim。每个 S3.1 子阶段继续交同一 reviewer。
