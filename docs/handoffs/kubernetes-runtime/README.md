# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4b `IN_PROGRESS`：S3.4a 资源输入与现状诊断已完成；当前实现标准 OCI/Task Update 在 Guest per-container cgroup 的 create/update、拒绝与回滚语义。

## 基线

最后一项已验证实现 commit 为 `2c4ebff5f17793fa229e473835ad860725118f51`，tree 为 `e458ef5920fa9e6288b1f84b79242c99f06c3ed5`。S3.4a v13 source SHA-256 为 `4934867f…`，containerd trace/helper 为 `88476ece…`/`61749200…`；live 原始 containerd 为 `15e00263…`，CubeShim 为 `3c715652…`，Agent ext4 为 `87bac7a6…`。私有 COS 输入对象为 `kubernetes-runtime/s3.4a/source/cubesandbox-s34a-source-v13-4934867f.tar.gz`。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3 和 S3.4a 全部 `DONE`。S3.4a 冻结 Kubernetes 1.36/containerd 2.3 的高低层资源边界：runc 对照生效；Cube 收到 raw create/update 输入但 Guest controller 保持默认，Shim/后代全部继承 `containerd.service`，尚无 Host Pod VM envelope；terminated classic init resize 仅更新 kubelet accounting；ephemeral-storage 保持 kubelet/snapshotter 责任。同一 reviewer 最终给出 `APPROVE S3.4a DONE`。

## 未完成

S3.4b～S3.4d 尚未完成。S3.4b 需补齐 Guest CPU、memory limit/reservation、swap、cpuset、PIDs、hugepage 和允许的 unified create/update，修复 `hugetlb..max` 与 swap-only 语义，并让无法执行的字段 fail-closed；之后 S3.4c 实现 Host Pod VM 包络，S3.4d 完成压力与故障回归。S3.3 的 TTY/stdin、Host device/GPU 和二期安全字段边界保持不变。

## 验证

S3.4a 构建 `inv-984tmbgax4`、稳定预检 `inv-v84tnd0995`、正式 V14 `inv-884tns09r5` 和独立审计 `inv-384tqf09ng` 均为 `SUCCESS`。核心证据目录为 `/data/cubelet/s3.4-evidence/s34a-20260901T141620Z-2459937`；覆盖 6 个高层 Pod、17 个成功低层 Task、1 个预期 create reject、2 个 invalid-unified 和 20 份 trace protobuf。raw create/update 均验证，正式脚本与审计均确认 `cleanup=exact`；三项服务 active、Node healthy，原始 containerd 恢复且测试对象无残留。完整摘要见 `evidence/s3.4/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 继续 `VALIDATING`：S3.4a 已冻结现状，S3.4b/c/d 仍需分别闭环 Guest、Host 包络和压力/故障语义。只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

执行 S3.4b：先冻结 Host Shim→Agent 的无损资源协议和 Guest cgroup v2 写入顺序；补齐 create/update 的 CPU、memory、swap、cpuset、PIDs、hugepage 与允许的 unified 字段，对不支持/非法输入 fail-closed。单元与故障测试通过并由同一 reviewer 批准后，再在项目 CVM 上重放 S3.4a 低层矩阵并增加 CPU throttle、定向 memory OOM、PIDs/hugepage 正反例和 sibling survivor 验证；完成前不得进入 S3.4c。
