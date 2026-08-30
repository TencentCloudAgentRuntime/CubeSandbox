# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

`S0 - 架构技术探针`。Owner：待指定。状态：方案和开发计划已完成，可开始 S0-1。

## 基线

最后已验证的实现提交：`09274501dd12e47dbed2dcc77d8eb67dd661d49c`。当前尚无 Kubernetes RuntimeClass 实现提交；本工作区只有方案、计划和轻量流程文件。

## 已完成

- 总体技术方案已保存，并补充社区可接受的组件边界和增量演进原则。
- 开发计划已按 S0～S6 拆分，每个 Stage 包含目标、范围和验收标准。
- 已建立 500 字内 handoff 规则及单表未决问题记录。
- 中文索引和 VitePress 侧边栏已加入方案入口。

## 未完成

- S0 四项技术探针。
- S1～S5 RuntimeClass PoC 实现与验收。
- S6 Snapshot/Restore/Pause/Resume 二期实现。

## 验证

- `make handoff-validate`：通过，2026-08-30。
- `cd docs && npm run docs:build`：通过，VitePress 1.6.4，2026-08-30。
- `git diff --check`：通过，2026-08-30。

## 阻塞

无外部阻塞。S0 开始前需要为 `K8S-OQ-001`～`K8S-OQ-004` 指定 owner。

## 受保护路径

- `docs/zh/dev/kubernetes-runtime-integration.md`
- `docs/zh/dev/kubernetes-runtime-integration-development.md`
- `docs/handoffs/kubernetes-runtime/`
- `docs/dev/handoff-policy.md`
- `docs/.vitepress/config.mjs`
- `docs/zh/dev/index.md`
- `Makefile`

## 下一步

1. 指定 S0 owner，并把 `K8S-OQ-001`～`K8S-OQ-004` 改为 `VALIDATING`。
2. S0-1：验证 containerd 2.3 Sandbox API 调用顺序和最小配置。
3. S0-2：验证标准 rootfs 与固定 virtiofs shared root 的动态 bind/unmount。
4. S0-3：选择首个 CNI 并验证 Pod IP、DNS、Service、NetworkPolicy 和跨节点路径。
5. S0-4：评审 CubeShim ↔ Cubelet、CubeShim ↔ Agent 的最小版本化接口。
