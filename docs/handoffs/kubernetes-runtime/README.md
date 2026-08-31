# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.1 `VALIDATING`：本地与隔离 containerd 可靠性闭环、production 云测入口及代码复审已通过，等待云端真实 TAP/完整 Cube VM 成功链路。

## 基线

S1.1 最后已验证实现 `76c7f760`（tree `6b152141e2346c5446d344bec26a6465d4353401`）；云端当前源码为 `37e08b32`（tree `404ecb2d1a0fab21c1edcb6c74c8145c86950658`）；S0 收口 `8db49456`。

## 已完成

S1.1 已实现 Sandbox VM 生命周期、Cubelet adapter/recovery、真实 FD handoff、确定性 cleanup identity、Release-before-Prepare durable fence、dead-shim bundle 外持久 reaper queue 与 Cubelet startup/continuous scanner；production Linux RuntimeResource 云测服务和完整 Controller 生命周期探针已加入。隔离 containerd 的 job-only 重启恢复通过，新增入口经五轮复审 `APPROVE`。

## 未完成

尚未在我们创建的 `ins-4dyul5ag`（名称含“勿删”）用当前源码完成真实 TAP/完整 Cube VM Create→Start→Status→Stop→Shutdown、清理检查和 S1.1 最终复审。

## 验证

CubeShim 105 项单测、cargo fmt check 与 all-targets cargo check 通过；Cubelet RuntimeResource/plugin/production harness 与 sandbox-probe Go race/vet 通过。隔离 containerd 2.3.4 中停止 Cubelet、生成 durable job、终止本次 detached reaper 后，仅靠同状态重启的 startup scanner 完成 Release；job/adapter/bundle 清空且 containerd 未重启。证据见 `evidence/s1.1/README.md`。

## 阻塞

旧 207627-byte 源码补丁已按用户授权上传到我们创建的私有 COS `cubesandbox-k8s-poc-20260831-1251707795`，并在我们创建的两台 CVM 展开校验成功。云端公网 Cargo 源不可用，Tencent Go proxy 的 containerd 模块校验和不可信；继续构建需要用户明确批准两个新 payload 上传到同一私有 COS 并下载到我们创建的 CVM：一是 10385-byte 增量补丁（SHA-256 `546ecb63fbf5f97a062ef5b5e526ff0b5a7d48df1f50b2bcc4f5de1f1764c90f`），二是 84415811-byte 离线 vendor 包（SHA-256 `68c419e6c89e6e6751620952a67c2c55352a859f31696588492f8f2b659935d9`）。不得绕过明确授权。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、相关文档；仅操作本 PoC 自建云资源。

## 下一步

获得上述两个精确 payload/目的地传输批准后，在 `ins-pl7mznaa` 离线构建，在 `ins-4dyul5ag` 跑真实 TAP/完整 Cube VM 生命周期、宿主残留与异常回滚验收；通过后交同一 subagent 做 S1.1 最终复审直至 `APPROVE`，再进入 S1.2。
