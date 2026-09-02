# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.4c.2 `VALIDATING`：Host leaf lifecycle、进程归位、bundle 外 takeover/scanner 和 Create/Delete failure barrier 已实现；当前执行剩余云端故障、漂移、重启与 legacy 验收。

## 基线

最后一项已验证实现 commit 为 `fe2f47cb17a3f6f256dc22eb5ff73ce60566beb1`，tree 为 `8c3daa1ee894565a7f3bac697976507a589e6a47`；上一个验收证据 commit 为 `136df12cd60ee3fa8b5e25759611cd68db3753fc`。项目 CVM 当前 CubeShim SHA-256 为 `1cce8aa4…`，固定 commit 云端 50 项 Host lifecycle 测试、RuntimeClass Pod 与 SIGKILL/30 秒兜底已通过。

## 已完成

S0、S1、S2.1～S2.4、S3.1～S3.3、S3.4a～S3.4b 与 S3.4c.1 全部 `DONE`。S3.4c.1 冻结 kubelet parent/Cube static leaf/Guest per-container 三层 owner、12 个预算向量、classifier/path、immutable/containment identity、external lifecycle + 双 cleanup owner、epoch/revoke、INTENT-before-write WAL 与封闭恢复表；systemd 200 次行为门禁和同一 reviewer 批准均完成。

## 未完成

S3.4c.2～S3.4d 尚未全部完成。S3.4c.2 还需 sibling containment/PID 诱饵、containerd restart、legacy Task 和最终 reviewer closure；S3.4c.3 的 controller WAL/RuntimeClass overhead 与 S3.4c.4 压力矩阵尚未开始。极端 unchecked `memory.max` 下调按 `K8S-OQ-017` 跟踪。

## 验证

`fe2f47cb` 由同一 reviewer 复审为 P0/P1=0 并 `APPROVE THIS FIX`；`inv-085uf4g092` 固定构建 50/50，`inv-885uk4gin4` 部署并通过本 build/boot 的 systemd 200 次 gate，`inv-985umh0f8d` 真实 RuntimeClass Pod 启停/日志/exec/Host leaf/exact cleanup 通过。`inv-v85umsgm7x` 证明 shim SIGKILL 后 durable FAILED、epoch fence、未 drain waiter 保留 30.698 秒后 exact cleanup。`inv-685vvwg356` 证明显式 120 秒客户端 timeout 下 live Delete 后五秒内 RuntimeResource=EMPTY、epoch 2→3，release 后收敛；其中诊断 ERR trap 对预期 `wait rc=1` 打出误报文字，但任务 exit=0 且最终验收行通过，需干净重跑替换该证据。额外两节点 TKE `cls-1oqe2py4` 已 Ready；`inv-a85win0n3a` 的 Deployment 5/5、StatefulSet 3/3 与全 Pod HTTP/curl 验收通过。S0 三节点自建集群也已部署同一清单；`inv-b860n808vc` 验证 8 个 Pod 覆盖三节点，localhost、Service、稳定 DNS 和持续 curl 全部通过。两个环境都只作为默认 containerd 多节点基线，不冒充 Cube RuntimeClass 证据。

## 阻塞

无外部阻塞，也无待用户决策。live-delete 前两轮失败已定位为 `crictl` 默认短 timeout 导致 waiter 正常 drain；显式 120 秒后功能通过，当前只清理诊断 trap 误报并补干净证据。`K8S-OQ-014`～`K8S-OQ-016` 等待 S3.4c.2～c.4 最终关闭；`K8S-OQ-017`～`019` 继续跟踪极端内存下调、VM hotplug 与有限 Pod PID 语义。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`deploy/kubernetes/smoke/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 CVM/自建 Kubernetes、额外 TKE `cls-1oqe2py4` 及其节点 `ins-h06xpkbw`、`ins-lus07026`，以及私有 COS `cubesandbox-k8s-poc-20260831-1251707795`；现有证据、构建产物和回滚副本不覆盖，名称带“勿删”的资源不得删除。

## 下一步

先干净重跑 live Create/并发 Delete；随后完成 sibling containment breach + 同 executable/argv PID 诱饵、containerd restart 时现有 Pod 可用、legacy Task 与最终零基线。更新 S3.4c 实际契约/证据后交同一 reviewer，直到明确 `APPROVE S3.4c.2` 才进入 S3.4c.3。
