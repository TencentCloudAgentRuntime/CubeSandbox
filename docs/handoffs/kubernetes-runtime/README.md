# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.2 `IN_PROGRESS`：S3.4c.1 的 Host Pod VM 包络设计已冻结，同一 reviewer 四轮复审后明确给出 `APPROVE S3.4c DESIGN`。当前实现 managed/legacy 分类、Host leaf 生命周期、进程归属、bundle 外 takeover 与长期 scanner。

## 基线

最后一项已验证实现 commit 为 `be8e7304c7ada8b4e7e13af8727613357a575bfb`，tree 为 `7aae3e6a7a96f76377be07a99f48da74ae769c76`；验收证据 commit 为 `136df12cd60ee3fa8b5e25759611cd68db3753fc`。项目 CVM 的最终 CubeShim/Agent SHA-256 为 `398416c5…`/`2e3318e6…`，resources-v2 capability 已启用并完成 missing/version-zero fail-closed 验证。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b 与 S3.4c.1 全部 `DONE`。S3.4c.1 冻结 kubelet parent/Cube static leaf/Guest per-container 三层 owner、12 个预算向量、classifier/path、immutable/containment identity、external lifecycle + 双 cleanup owner、epoch/revoke、INTENT-before-write WAL 与封闭恢复表；systemd 200 次行为门禁和同一 reviewer 批准均完成。

## 未完成

S3.4c.2～S3.4d 尚未完成。Host 上尚无 Pod VM leaf，Shim/VMM/virtiofs/辅助进程仍继承 containerd service cgroup；watchdog、external owners、gate/identity、controller WAL、RuntimeClass overhead、云端压力和重启恢复待实现。极端 unchecked `memory.max` 下调按 `K8S-OQ-017` 跟踪。

## 验证

S3.4b 验证保持不变。S3.4c.1 输入探针 `inv-v856u30wn5`、`inv-985738gw5i`、`inv-v8576v08e1`、`inv-a857xtgv7s` 成功；有效 systemd 门禁 `inv-38589x0k30` 为 200/200、failures=0、cleanup exact、dropped=0。早期无效探针已排除并由 `inv-v858720f7k`、`inv-08589cgxsg` 精确清理。证据见 `evidence/s3.4/s3.4c-*`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 已有设计结论，等待 S3.4c.2～c.4 实现/压力关闭；`K8S-OQ-017`～`019` 继续跟踪极端内存下调、VM hotplug 与有限 Pod PID 语义。只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

执行 S3.4c.2：先实现 classifier/path 与 external lifecycle/双 owner schema，再实现 watchdog service、readiness gate、ServerIdentity/pidfd、systemd/cgroupfs leaf 和 cleanup state machine；补 response 后 failpoints、containment breach/PID 诱饵、containerd restart/kill Shim/legacy tests。全部本地与特权验证通过后交同一 reviewer，直到明确 `APPROVE S3.4c.2` 才进入 S3.4c.3。
