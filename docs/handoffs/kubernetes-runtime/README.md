# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

当前入口：`S0.1 Sandbox API`，状态 `IN_PROGRESS`，Owner `Codex`。全部 Stage 进度直接维护在 [PoC 开发计划](../../zh/dev/kubernetes-runtime-integration-development.md)，本文件不复制进度表。

## 基线

最后已验证的实现提交：`09274501dd12e47dbed2dcc77d8eb67dd661d49c`；当前尚无 Kubernetes RuntimeClass 实现提交。最新 Stage 记录提交：`81c5332f`。

## 已完成

- 创建香港二区 PVM 验证机 `ins-pl7mznaa`（16C32G，`img-qansmwme`），复用 `cubesandbox-cluster-subnet`，使用专属安全组 `sg-k3absy6z`。
- 验证 `kvm_pvm`、`/dev/kvm`、KVM API 12 和 `KVM_CREATE_VM`；200GB XFS reflink 数据盘挂载于 `/data/cubelet`。
- 将 containerd 升级到官方 `v2.3.4`；客户端/服务端、CRI images/runtime 与 Docker 29.2.1 均正常。
- 云节点按精确基线 `09274501` 完成 `make shim`；`make shim-test` 中 shim 61 个、cube-runtime 1 个测试通过。

## 未完成

- 尚未启动完整 Cube Guest，也未实现 containerd 2.3 最小 Sandbox shim。
- 尚缺 CRI/Sandbox/Task 调用 trace、`sandboxer = "shim"` 最小配置和异常清理证据。
- 尚未创建专属 TKE；待 S0.1/S0.2 证明主路径后再创建 Kubernetes 1.36.2 集群。

## 验证

- TAT `inv-3822g20r7i`：PVM/KVM、containerd/CRI、XFS、源码、产物和测试汇总检查通过。
- TAT `inv-38221eg40s`：`make shim` 通过；TAT `inv-6822eegkw4`：`make shim-test` 通过。
- `make handoff-validate`：通过，2026-08-30。
- `cd docs && npm run docs:build`：通过，VitePress 1.6.4，2026-08-30。
- `git diff --check`：通过，2026-08-30。

## 阻塞

没有技术阻塞。实例公网 SSH 转发返回 `502 Server UnReachable`，但 TAT Agent 在线且可稳定执行构建/测试；账号香港 VPC 数量已达上限，因此当前复用既有 CubeSandbox 子网。

## 受保护路径

- `docs/zh/dev/kubernetes-runtime-integration-development.md`
- `docs/handoffs/kubernetes-runtime/`
- `docs/dev/handoff-policy.md`

## 下一步

1. 先复现 TAT `inv-3822g20r7i` 的关键结果，确认 `/dev/kvm`、containerd 2.3.4 和源码基线未漂移。
2. 明确 containerd 2.3 Sandbox Controller/shim bootstrap 契约，给现有 CubeShim 增加最小 feature-gated Sandbox 服务。
3. 在该节点配置 `sandboxer = "shim"`，记录 RunPodSandbox、Sandbox、Task 和清理 trace。
4. 覆盖正常删除、创建中取消和 shim 崩溃清理；证据闭合后才把 S0.1 改为 `VALIDATING`/`DONE`。
5. S0.1/S0.2 主路径成立后，再创建专属 TKE 1.36.2 集群并开始 RuntimeClass E2E。
