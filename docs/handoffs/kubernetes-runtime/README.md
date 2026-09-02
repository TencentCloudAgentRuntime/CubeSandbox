# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4d `VALIDATING`：实现、云端矩阵和环境清理已完成，等待同一 reviewer 终审。持续长
exec + 同容器 resize 的超时已冻结为首版 P1 已知限制并转 S5.4，不阻断基础 Kubernetes
E2E。

## 基线

最后一项已验证实现 commit 为 `6662316e`；S3.4c 最终证据 commit 为 `24d2d188`。S0 双
Worker 当前 CubeShim/Agent ext4 SHA-256 为 `a4974713…`/`c768706b…`；`cube-runtime`
保持既有制品；运行时根为
`/opt/cubesandbox-s0-multinode-runtime-2269a3b3`。

## 已完成

S0、S1、S2、S3.1～S3.3、S3.4a～S3.4c 均为 `DONE`。S3.4d 已关闭
`K8S-OQ-015/016/017/021`，完成生命周期 fence、受控 restart/resize/long-exec、
ephemeral-storage、QoS/多容器双层数值和最终清理；
两个 Worker 均为 0 sandbox/VM/CNI/shim/mount/active lease，集群 3/3 Ready。

## 未完成

S3.4d 只差同一 reviewer 终审。批准后立即运行官方 Kubernetes v1.36.4 Node
E2E/Conformance，逐项分类失败并优先修复阻断主路径的问题。

## 验证

S3.4d 最终验证：`inv-686k7g02nv` 默认规格启动即 OOM 8/8 为 `OOMKilled/137`；
`inv-v86ksj0ndb` 完成 restart/两次 resize/受控长 exec；`inv-686ktxgext`、
`inv-886ku00590`、`inv-a86kufg720` 完成 Guest/Host 组合矩阵；
`inv-086ncr074p` 完成最终 lifecycle regression；`inv-a86ndt0pkt`/`inv-a86nds0c3q` 双
Worker exact zero；`inv-v86nea09kv` 为 3/3 Ready。完整证据见
[S3.4d 摘要](./evidence/s3.4/s3.4d-execution-summary.md)。

## 阻塞

无外部阻塞或待用户决策。P1 已知限制为持续长 exec + 同容器 resize 仍可能使首次
Update/探针超时；kubelet 重试后 resize 收敛，资源可精确清理。该组合不属于首版支持面，
在 `K8S-OQ-022` 转 S5.4 整改。另有 12 Sandbox 创建即取消的瞬时 `FailedKillPod`，重试
后 exact-zero，按 `K8S-OQ-023` 转 S5.4。二者均不阻断基础 E2E。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、
`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。
云端仅操作本 PoC 创建的资源；名称带“勿删”的 CVM/TKE 不得删除。现有证据、构建产物和
回滚副本不得覆盖，handoff 不记录凭证。

## 下一步

1. 同一 reviewer 复核 `6662316e`、S3.4d 证据和已知限制分类。
2. 若有 P0/P1 阻断项则修复并复审；批准后把 S3.4/S3.4d 标记 `DONE`。
3. 在 W1 临时把 containerd default runtime 切到 Cube，运行官方 Kubernetes v1.36.4
   Node E2E/Conformance；完成后恢复 runc 默认值。
4. 对每个 E2E 失败分类、关联日志和问题 ID，优先关闭主路径阻断项。
