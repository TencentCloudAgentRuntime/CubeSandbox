# S0.2 RootFS/virtiofs 云端证据

## 结论

在腾讯云香港二区真实 PVM 节点上，CubeShim 已能消费 containerd 2.3.4 标准
`CreateTaskRequest.rootfs`，把 overlayfs active snapshot 的 upper/lower layers 导出到
virtiofs，并在 Cube Guest 内启动 BusyBox。退出码 23 准确返回；动态挂载矩阵通过；
20 次创建/删除后 mount、share、Task、Container、Shim 均为 0。

## 环境

- CVM：`ins-pl7mznaa`，`SA5.4XLARGE32`，16C32G，香港二区。
- Host kernel：`6.6.69-opencloudos9.cubesandbox.pvm.host-g0de43d6b3bcd`。
- Guest kernel：官方匹配 PVM Guest，SHA256
  `f9ecd86a05ddefc56dc6ae4b5c3448bb6c96c46ccc82fe344c5199560d7adb71`。
- containerd：`v2.3.4`，隔离 root/state/socket；`/data/cubelet` 为 XFS。
- image：`docker.io/library/busybox:1.36.1`。
- 完整非敏感环境输出见 `environment.txt`。

## 可复现入口

- 配置：`CubeShim/s0-rootfs-probe/containerd.toml`。
- 验收：`CubeShim/s0-rootfs-probe/run.sh`。
- feature gate：`io.containerd.cube.s0.standard-rootfs=true`。

最终云端执行直接使用仓库脚本内容作为 TAT command content，没有另写验收逻辑。

## 最终任务

| 用途 | TAT Invocation | 结果 |
|---|---|---|
| 最终 build + 68 个 CubeShim tests + release | `inv-9827fk0njh` | `SUCCESS`，binary SHA256 `42540813c93a59dec90ab12c61f00457571632c9d21f1ac5ab9b18e2af31b31a` |
| 最终 rootfs/dynamic/20-cycle 验收 | `inv-9827ikgt4f` | `SUCCESS`，27 秒 |
| 最终环境采集 | `inv-0827k8gnsw` | `SUCCESS` |

最终验收摘要见 `acceptance-summary.txt`。Task ID 为 `invt-9827ikgt4g`，执行时间
`2026-08-30T14:24:42Z`～`14:25:09Z`，exit code 0。

## 负向对照与架构决定

- Host merged overlay 直接经 virtiofs 作为 Guest overlay lower：Guest 返回 `EINVAL`，
  TAT `inv-a826rq0iv4`。因此改为逐层导出 active upper + image lowers。
- 分层导出但 `announce_submounts=true`：Guest 对两个 layer lower 仍返回 `EINVAL`，
  TAT `inv-b827bfgaqh`。最终固定为 `announce_submounts=false`。
- `announce_submounts=false` 下，Guest lookup 后 Host 普通 `umount` 返回 `EBUSY`；
  `MNT_DETACH` 后 Host mount 计数立即归零，但 Guest 可能保留旧 inode 到 Task/VM 删除。
  因此 S3 volume detach 必须采用 Guest-first consumer unmount、Host detach、generation
  路径不复用；最终验收已证明 Task/VM 删除后所有引用和 mount 归零。

## 边界

Guest writable upper 当前是临时层，不回写 containerd active upper。S0/S1 只要求运行
和删除语义；持久化 writable layer、容器重启对账及 snapshotter 协同在 S3 决定。
