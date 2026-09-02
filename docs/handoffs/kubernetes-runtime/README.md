# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.2 `VALIDATING`：Host leaf lifecycle、进程归位、bundle 外 takeover/scanner 和 Create/Delete failure barrier 已实现；S0 双工作节点的 8 VM 跨节点 Cube 回归已通过，当前继续剩余云端故障、漂移、重启与 legacy 验收。

## 基线

最后一项已验证实现 commit 为 `2269a3b3248bda1259cec722fbdd1d20cf843bbd`，tree 为 `ca969122cc3e2abeab8254bdacf5ee8a0a35462c`；上一个验收证据 commit 为 `4c6b8b25`。S0 双工作节点当前 CubeShim/Agent/`cube-runtime` SHA-256 为 `9cfaf6d3…`/`870fd590…`/`8c17375d…`；固定 commit 云端 20 项 standard-rootfs 测试、8 Pod 跨节点 RuntimeClass 回归、原有 50 项 Host lifecycle、RuntimeClass Pod 与 SIGKILL/30 秒兜底均通过。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b 与 S3.4c.1 全部 `DONE`。S3.4c.1 冻结 kubelet parent/Cube static leaf/Guest per-container 三层 owner、12 个预算向量、classifier/path、immutable/containment identity、external lifecycle + 双 cleanup owner、epoch/revoke、INTENT-before-write WAL 与封闭恢复表；systemd 200 次行为门禁和同一 reviewer 批准均完成。

## 未完成

S3.4c.2～S3.4d 尚未全部完成。S3.4c.2 还需 sibling containment/PID 诱饵、containerd restart、legacy Task 和最终 reviewer closure；S3.4c.3 的 controller WAL/RuntimeClass overhead 与 S3.4c.4 压力矩阵尚未开始。极端 unchecked `memory.max` 下调按 `K8S-OQ-017` 跟踪。

## 验证

`fe2f47cb` 由同一 reviewer 复审为 P0/P1=0 并 `APPROVE THIS FIX`；`inv-085uf4g092` 固定构建 50/50，`inv-885uk4gin4` 部署并通过本 build/boot 的 systemd 200 次 gate，`inv-985umh0f8d` 真实 RuntimeClass Pod 启停/日志/exec/Host leaf/exact cleanup 通过。`inv-v85umsgm7x` 证明 shim SIGKILL 后 durable FAILED、epoch fence、未 drain waiter 保留 30.698 秒后 exact cleanup。`inv-685vvwg356` 证明显式 120 秒客户端 timeout 下 live Delete 后五秒内 RuntimeResource=EMPTY、epoch 2→3，release 后收敛；其中诊断 ERR trap 对预期 `wait rc=1` 打出误报文字，但任务 exit=0 且最终验收行通过，需干净重跑替换该证据。额外两节点 TKE `cls-1oqe2py4` 的默认 runtime 5+3 基线保持。S0 自建集群现另有真实 Cube 验收：`inv-8863x002rx` 为 8 个 Pod 2/2 Ready，`inv-8863xngiss` 完成 64 次 PodIP、30 次跨节点、24 次稳定 DNS 和 24 次 ClusterIP；`inv-38640k0ru9`/`inv-88640n0hs5` 确认 3/5 个 `io.containerd.cube.rs` sandbox 与 VM/lease 精确一致，`inv-98642mgspg` 确认 8 个非 root resolver 与只读 bind。`inv-v86aek0p10` 又以同一 commit 的 `cube-runtime` 补齐两个 Worker，`inv-v86aem0qtx` 确认安装后 8/8 Pod、0 restart 与 Service DNS 8/8。详见 [跨节点证据](./evidence/s3.4/s0-cube-crossnode-workloads.md)。

## 阻塞

无外部阻塞，也无待用户决策。用户请求的 S0 跨节点 Cube 验证环境已经可用并保留 8 个运行中 Pod。live-delete 前两轮失败已定位为 `crictl` 默认短 timeout 导致 waiter 正常 drain；显式 120 秒后功能通过，当前只清理诊断 trap 误报并补干净证据。`K8S-OQ-014`～`K8S-OQ-016` 等待 S3.4c.2～c.4 最终关闭；`K8S-OQ-017`～`019` 继续跟踪极端内存下调、VM hotplug 与有限 Pod PID 语义。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 CVM/自建 Kubernetes、额外 TKE `cls-1oqe2py4` 及其节点 `ins-h06xpkbw`、`ins-lus07026`，以及私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖，名称带“勿删”的资源不得删除。

## 下一步

用户可先在两个 Worker 用 `/usr/local/bin/cube-runtime` 做 Guest/底层 snapshot 调试，并在 `ins-qj8d7ypa` 用 `/etc/kubernetes/admin.conf` 验证 `cubesandbox-cube-crossnode`；不要缩容或替换这 8 个 Pod，除非开始下一项破坏性验收。随后干净重跑 live Create/并发 Delete，再完成 sibling containment breach + 同 executable/argv PID 诱饵、containerd restart 时现有 Pod 可用、legacy Task 与最终零基线。更新 S3.4c 实际契约/证据后交同一 reviewer，直到明确 `APPROVE S3.4c.2` 才进入 S3.4c.3。
