# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.1 `VALIDATING`：本地与隔离 containerd 可靠性闭环及代码复审已通过，等待云端真实 TAP/完整 Cube VM 成功链路。

## 基线

S1.1 最后已验证实现 `37e08b32`（tree `404ecb2d1a0fab21c1edcb6c74c8145c86950658`）；S0 收口 `8db49456`。

## 已完成

S1.1 已实现 Sandbox VM 生命周期、Cubelet adapter/recovery、真实 FD handoff、确定性 cleanup identity、Release-before-Prepare durable fence、dead-shim bundle 外持久 reaper queue 与 Cubelet startup/continuous scanner；隔离 containerd 的 job-only 重启恢复通过，代码 reviewer 已 `APPROVE`。

## 未完成

尚未在我们创建的 `ins-4dyul5ag`（名称含“勿删”）用当前源码完成真实 TAP/完整 Cube VM Create→Start→Status→Stop→Shutdown、清理检查和 S1.1 最终复审。

## 验证

CubeShim 105 项单测、cargo fmt check 与 all-targets cargo check 通过；Cubelet RuntimeResource/plugin 与 sandbox-probe Go race/vet 通过。隔离 containerd 2.3.4 中停止 Cubelet、生成 durable job、终止本次 detached reaper 后，仅靠同状态重启的 startup scanner 完成 Release；job/adapter/bundle 清空且 containerd 未重启。证据见 `evidence/s1.1/README.md`。

## 阻塞

执行策略要求用户明确批准：把基线 `09274501dd12e47dbed2dcc77d8eb67dd661d49c` 到实现 `37e08b325b5dd39f3a06b44d7da941aa800141b1` 的 207627-byte gzip binary patch（SHA-256 `532ddfcb57d22c77a5f50c8b9ae74621f90fd906359a89611976a3e82dd503c5`）上传到我们创建的私有 COS `cubesandbox-k8s-poc-20260831-1251707795`，并只下载到我们创建的 CVM `ins-4dyul5ag`。临时干净基线重放 tree 与目标 `404ecb2d1a0fab21c1edcb6c74c8145c86950658` 一致；不得绕过明确授权。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、相关文档；仅操作本 PoC 自建云资源。

## 下一步

获得上述精确 payload/目的地传输批准后，在 `ins-4dyul5ag` 构建并跑真实 TAP/完整 Cube VM 生命周期与清理验收；通过后交同一 subagent 做 S1.1 最终复审直至 `APPROVE`，再进入 S1.2。
