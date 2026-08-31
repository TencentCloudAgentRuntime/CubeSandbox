# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.4 `IN_PROGRESS`：S1.3 CRI 基础交互已完成；当前开始清理、runc 共存、Job/Deployment 和 legacy Cubebox 回归。

## 基线

最后一项已验证实现 commit 为 `14354f09cd9d7b384f4170e3ef1ccafb12e4bccd`，完整 tree 为 `5ce41abfaa77f1979cca53b7751b620506415538`。S1.3 最终 shim SHA-256 为 `f873cdbe2cf63cbcf5c809ffc9035ba4066d6a92dc658599c50fd513586c253d`。

## 已完成

S0、S1.1、S1.2、S1.3 均为 `DONE`。S1.3 已让标准 Kubernetes `RuntimeClass/cube` 单容器 Pod 在真实 Cube VM 运行；logs、非 TTY/非 stdin exec、退出码、termination grace period 和退出事件正确。Kubernetes host bind mount 经 Pod 固定 virtio-fs share 导入 Guest；unmount 失败时保留 export。删除后 containerd、snapshot、netns、RuntimeResource、mount、shim 和 active lease 全部恢复基线，同一 reviewer 最终 `APPROVE`。

## 未完成

S1.4 尚未完成正常/强制/创建中取消清理矩阵、100 次循环、Job/Deployment、默认 runc 共存和 legacy Cubebox smoke。因此 S1 Milestone 仍为 `IN_PROGRESS`。TTY/stdin 属于后续范围，不纳入 S1.4。

## 验证

最终严格构建 `inv-683bb60cjf` 通过 CubeShim lib tests、all-targets check 和 release build；最终部署 `inv-883besgxts` 成功。真实 Kubernetes 终验 `inv-383bfj082n` 为 `SUCCESS`：exec 进程/客户端返回 19，3 秒 grace 后 SIGKILL 返回 137，删除耗时 4451 ms，所有断言资源恢复基线。完整摘要见 `evidence/s1.3/README.md`。

## 阻塞

无外部阻塞。containerd verbose status 对 Sandbox 空 `Spec.type_url` 的 warning 已记录为 `K8S-OQ-009`，在 S1.4 兼容性回归处理，不影响已验证生命周期。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

接手者先复现 `evidence/s1.3/README.md` 的最终制品 SHA、`inv-383bfj082n` 的 logs/exec/137 和零残留结论。随后冻结 S1.4 验收矩阵，依次验证正常删除、强制删除、创建中取消、100 次循环、默认 runc、Job/Deployment 和 legacy smoke；每个独立小步保留前后基线，完成后交同一 reviewer。不要提前展开 S2 多容器或 TTY/stdin。
