# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

当前入口：`S0.1 Sandbox API`，状态 `NOT_STARTED`，Owner 待指定。全部 Stage 进度直接维护在 [PoC 开发计划](../../zh/dev/kubernetes-runtime-integration-development.md)，本文件不复制进度表。

## 基线

最后已验证的实现提交：`09274501dd12e47dbed2dcc77d8eb67dd661d49c`；当前尚无 Kubernetes RuntimeClass 实现提交。最新计划提交：`9f2be25b`。

## 已完成

- 总体技术方案及 S0～S6/Sx.x 目标和验收标准已形成。
- 每个 `Sx` 已直接加入 `Sx.x` 状态、Owner、已完成、证据和下一步字段。
- 方案准备记录为 `DONE`；所有尚未实施的 Work Stage 记录为 `NOT_STARTED`。

## 未完成

当前待执行项为 S0.1：验证 containerd 2.3 Sandbox API 调用顺序、最小配置和异常清理责任。

## 验证

- `make handoff-validate`：通过，2026-08-30。
- `cd docs && npm run docs:build`：通过，VitePress 1.6.4，2026-08-30。
- `git diff --check`：通过，2026-08-30。

## 阻塞

没有技术阻塞；开始 S0.1 前需指定 Owner。

## 受保护路径

- `docs/zh/dev/kubernetes-runtime-integration-development.md`
- `docs/handoffs/kubernetes-runtime/`
- `docs/dev/handoff-policy.md`

## 下一步

1. 指定 S0.1 Owner。
2. 在开发计划中把 S0.1 更新为 `IN_PROGRESS`，并填写实际下一步。
3. 把 `K8S-OQ-001` 更新为 `VALIDATING`。
4. 执行 containerd 2.3 最小 shim 探针，记录配置、调用 trace、清理行为和结果。
5. 验收开始后把 S0.1 更新为 `VALIDATING`；全部标准通过后才能标记 `DONE`。
