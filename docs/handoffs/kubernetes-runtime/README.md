# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.1 `IN_PROGRESS`：S3.4b 的四个实现单元及云端终验均已关闭，同一 reviewer 已给出 `APPROVE S3.4b DONE`。当前冻结 Host Pod VM 资源包络的输入、预算算法、cgroup owner/path 和生命周期事务。

## 基线

最后一项已验证实现 commit 为 `be8e7304c7ada8b4e7e13af8727613357a575bfb`，tree 为 `7aae3e6a7a96f76377be07a99f48da74ae769c76`；验收证据 commit 为 `136df12cd60ee3fa8b5e25759611cd68db3753fc`。项目 CVM 的最终 CubeShim/Agent SHA-256 为 `398416c5…`/`2e3318e6…`，resources-v2 capability 已启用并完成 missing/version-zero fail-closed 验证。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b 全部 `DONE`。S3.4b 已实现 resources-v2 严格协议、presence/partial merge、controller transaction、rollback/undo replay、degraded 门禁和 PendingCreate 清理；数值、压力/OOM/PIDs/hugepage、真实故障、capability、legacy、Kubernetes resize 与全量清理均通过，同一 reviewer 已最终批准。

## 未完成

S3.4c～S3.4d 尚未完成。Host 上尚无 Pod VM 总量包络，Shim/VMM/virtiofs/辅助进程仍继承 containerd service cgroup；预算计算、Host controller transaction、动态更新、重启恢复和双层压力矩阵待实现。极端 unchecked `memory.max` 下调可能超过 10 秒 Guest RPC，按 `K8S-OQ-017` 跟踪，不计作 S3.4b 通过能力。

## 验证

S3.4b 的本地 Agent resources/device/capability、Shim resources/rootfs/device policy 和 Go helper 独立复跑全部通过。云端 `inv-8853vxgxh1`、`inv-k852mwg8ud`、`inv-9855pngtst`、`inv-08564809p0`、`inv-68569j047d`、`inv-v856bt07f9` 与 `inv-6856c8gt1t` 均成功；固定输出、controller 读数和 cleanup 哈希见 `evidence/s3.4/s3.4b-*.txt`。

## 阻塞

无外部阻塞。`K8S-OQ-014`～`K8S-OQ-016` 进入 Host 包络设计与双层组合验证，`K8S-OQ-017` 记录极端 unchecked 内存下调的 RPC/异步语义；只操作本 PoC 创建的 CVM/自建 Kubernetes 和指定私有 COS，不触碰账号内其他资源。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、对应自建 Kubernetes 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖。

## 下一步

执行 S3.4c.1：只读梳理 RunPodSandbox/CreateTask/VM 启动与 containerd update 路径，冻结 Pod 有效预算算法、唯一 Host cgroup owner/path、Shim/VMM/virtiofs/辅助进程归属，以及创建、更新、删除、失败回滚和重启恢复状态机；形成固定测试向量和设计文档，交同一 reviewer 批准后进入 S3.4c.2。
