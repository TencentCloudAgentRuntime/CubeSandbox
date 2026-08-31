# S2.2 Init 与定向重启验收证据

## 结论

Kubernetes 现有 CRI desired-state 控制与 CubeShim 多 Task 实现已经覆盖 S2.2，无需修改
生产 Rust 代码：两个 init container 严格串行完成后才启动 app；失败 init 以新 Task
重试且 app 保持 `PodInitializing`；双业务容器中 alpha 退出后仅 alpha 被重建，beta、
Pod UID/IP、Sandbox、Cube VM 和 shim PID 均保持不变。每个 Pod 删除后均恢复 S2.1
全量资源基线。

验收脚本提交为 `9467e4a07d394b208a2acc2377e90133a0e763fc`；同一 reviewer 完成
最终复核并明确 `APPROVE`，无剩余 must-fix。

## 固定输入

- 已部署 shim SHA-256：
  `39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd`。
- 验收脚本：COS `s22/scripts/verify-s22-init-restart-cloud-v3.sh`，SHA-256
  `b896af6b8aaf2c65eb88f28db227966071feb1d24d168ef18fa0de0ff2327e05`。
- 运行环境：自建 Kubernetes 1.36 / containerd 2.3.4；控制平面
  `ins-pl7mznaa`，Cube runtime 节点 `vm-200-2-ubuntu`。

## 诊断基线

不依赖可写 volume 的三例诊断 `inv-983ggb0u6k` 为 `SUCCESS`：

- init-one、init-two 的完成顺序与 app 启动顺序正确；已完成 init Task 不再出现在
  containerd Task 集合中。
- init-flaky 第一次 exit `42`，restartCount 变为 1，新旧 container ID 不同；app
  未启动，Sandbox/VM/shim 不变。
- alpha 第一次 exit `23`，restartCount 变为 1，仅 alpha ID 变化；beta 仍可 exec。

最初诊断 `inv-983g950j53` 还发现 `/work/events: Read-only file system`：当前固定
virtio-fs share 以只读方式呈现，导致写入 `emptyDir` 失败。该问题属于 S3.1 基础
Volume，不属于 init/restart 生命周期；已记录为 `K8S-OQ-011`，S2.2 的终验不依赖
volume 跨 Task 传递状态。

## Kubernetes 终验

最终 TAT `inv-a83gx50k5f` 为 `SUCCESS`。执行前断言脚本与 shim SHA，三例结果为：

1. `init-success`：两个 init 均 exit `0`、restartCount `0`，时间戳满足
   init-one finished ≤ init-two started ≤ init-two finished ≤ app started；旧 init Task
   和 rootfs export 均为 0。
2. `init-retry`：第一次 init exit `42`，第二个 Task 正在运行，restartCount `1`；
   旧 Task/rootfs 已清理，app 尚未启动，Pod UID/IP、Sandbox、VM、shim PID 不变。
3. `app-restart`：alpha exit `23` 后只重建 alpha，restartCount `1` 且 Pod 恢复
   Ready；beta ID 不变并可 exec，旧 alpha Task/rootfs 已清理，VM/shim PID 不变。

每例删除后均逐项比较 container、Task、Sandbox、overlay snapshot、netns、Cube shim、
reaper、`/run/vc/vm`、mount 和 RuntimeResource active lease 的前后集合。最终脚本还
对 Sandbox、shim PID 和 active shared-root 强制 cardinality=1，并限制活跃 rootfs
export 总数。三例分别在 28、52、50 次 100 ms 轮询后恢复基线；active lease 为 0，
durable tombstone 总增量为 3。

```text
S22_INIT_SUCCESS_OK strict_order=ok stale_init_tasks=0 stale_init_rootfs=0
S22_INIT_RETRY_OK exit=42 restart_count=1 app_started=0 shim_pid_stable=ok
S22_APP_RESTART_OK exit=23 restart_count=1 pod_ready=ok shim_pid_stable=ok
S22_INIT_RESTART_OK cases=3 survivor=ok active_leases=0 durable_tombstone_delta=3 vm_runtime=baseline
```

完整证据位于
`/data/cubelet/s2.2-evidence/init-restart-20260831T135730Z`。
