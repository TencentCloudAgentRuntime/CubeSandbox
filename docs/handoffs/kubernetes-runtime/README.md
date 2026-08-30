# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S1.1 `VALIDATING`：本地协议和失败回滚已通过，等待云端真实 Cube VM 成功链路。

## 基线

S1.1 最后已验证实现 `f61d1317`；S0 收口 `8db49456`。

## 已完成

S1.1 已实现 containerd Sandbox Service 到 Cube VM 的生命周期、Cubelet adapter/recovery、真实 FD handoff；官方 containerd 2.3.4 跨语言 Create 和缺 KVM Start 精确 Release/tombstone 已通过。

## 未完成

尚未在 `ins-4dyul5ag` 用当前源码完成真实 Cube VM Create→Start→Status→Stop→Shutdown、清理检查和 subagent 最终复审。

## 验证

CubeShim 97 项单测、cargo fmt check 与 cargo check 通过；Cubelet RuntimeResource/plugin Go test-race/vet 通过；本地真实 containerd wire probe 的 Create 成功，Start 因无 `/dev/kvm` 明确失败并精确释放。证据见 `evidence/s1.1/README.md`。

## 阻塞

执行策略要求用户明确批准：把截至实现提交 `f61d1317` 的 179327-byte binary patch（SHA-256 `64c4b6eebfd08e05d30542b8a8dec96f4f6871a338df2924134d30145d831445`）上传到新建私有 COS `cubesandbox-k8s-poc-20260831-1251707795`，再下载到我们创建的 CVM `ins-4dyul5ag`。不得绕过。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、相关文档；仅操作本 PoC 自建云资源。

## 下一步

获得上述源码传输明确批准后，在 `ins-4dyul5ag` 构建并跑真实 VM 生命周期/清理验收；通过后交同一 subagent 反复复审直至 `APPROVE`。
