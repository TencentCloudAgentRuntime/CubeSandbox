# S2.3 Kubernetes Pod Namespace 验收证据

## 结论

S2.3 `DONE`。CubeShim 已把 CRI v1 Pod namespace 选项和 hostname 映射到单 Pod
Cube VM：默认模式下 net/IPC/UTS 共享、PID 与 mount 隔离；
`shareProcessNamespace: true` 时所有容器加入同一个由专用最小 PID 1 持有的 PID
namespace。`hostNetwork`、`hostPID`、`hostIPC` 在创建 VM 与 RuntimeResource 前明确
拒绝。

共享 PID holder 使用独立 mount namespace，exec 后不保留 Agent 内存或非 stdio FD，
进入空 tmpfs root，设置 non-dumpable/no-new-privileges，UID/GID 降为 65534 并清空
ambient、bounding、effective、permitted、inheritable capabilities。holder 通过 readiness
pipe 完成初始化握手并承担 PID 1 reaping。

实现提交为 `e1bc2b7a21b43f29d372c5c92e55ac9159fed18e`、
`72beea45`、`9b0c14fa`；验收脚本提交为
`a50425d308cd0c31b72e716d7e92bc7e945bcf3c`。同一 reviewer 对实现、构建集成、
镜像预解包基线和最终云端证据多轮复核，最终明确 `APPROVE`，无剩余 must-fix。

## 固定输入

- shim SHA-256：
  `0b89ae6d33bbe5cb5e10a02ba490fc4d9aae56d768863c30de7712bac242a4d5`。
- `cube-agent.ext4` SHA-256：
  `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`。
- 最终验收脚本：COS
  `scripts/s2.3/verify-s23-namespaces-cloud-3e36361c.sh`，SHA-256
  `3e36361c1b1380d874093879c9323f0d2b9bb3210322ff4530a12e03359fb039`。
- 运行环境：自建 Kubernetes 1.36 / containerd 2.3.4；控制平面与 Cube runtime
  节点均为本 PoC 创建的 `ins-pl7mznaa` / `vm-200-2-ubuntu`。

## 构建与部署

严格 Agent 测试与静态镜像构建 `inv-v83iix062d` 为 `SUCCESS`；其中
`make agent-test` 通过，`make agent-ext4` 同时打包两个 0755 静态 ELF。
`inv-v83ipj0gg6` 使用 debugfs 确认 ext4 内存在：

```text
/cube-agent          regular 0755
/cube-pidns-holder   regular 0755
agent_sha=b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9
image_size=20971520
```

版本化部署 `inv-883iq5gvea` 为 `SUCCESS`，资产目录为
`/opt/cubesandbox-s23-runtime-artifacts-holder-v1`。旧 namespace runtime 资产保留，
live Agent 链接只切换到新版本。

## 诊断与验收脚本加固

修复前诊断 `inv-983hbh003m` 证明默认 Pod 的 net/IPC/UTS 已共享、PID/mount 已隔离，
同时复现三个缺口：`shareProcessNamespace` 未生效，hostPID/hostIPC 被错误接受，hostname
使用 Sandbox ID。实现补齐 CRI v1 解码和映射后，reviewer 进一步发现裸 clone holder 会经
`/proc/1/root`、`/proc/1/exe`、`/proc/1/fd` 暴露 Agent 视图；因此改为专用 exec helper
并加入进程边界加固。

第一次最终脚本运行 `inv-083iskg20f` 在 runtime 分配前因节点 `DiskPressure` 驱逐测试
Pod；精确删除本 PoC 已被替代的旧构建树
`/opt/cubesandbox-s23-build/namespace-e1bc2b7a-v2` 后，可用空间从 12 GiB 恢复到
20 GiB，节点在 kubelet 的 5 分钟压力缓释窗口后恢复 `DiskPressure=False`。

第二次运行 `inv-383j2407hp` 的默认 namespace 用例已通过，但发现首次启动镜像后
containerd 会保留合法 immutable image-layer snapshot，使“尚未 unpack”的初始 snapshot
集合不适合作为清理基线。最终脚本在采集 baseline 前通过本地 `ctr images mount` 完成
预解包，再以 `images unmount --rm` 删除临时 view；reviewer 确认该方式仍对所有
per-container active snapshot 做精确集合比较，不会掩盖泄漏。

## Kubernetes 最终验收

最终 TAT `inv-a83j9u0q12` 为 `SUCCESS`、exit code 0，完整证据位于
`/data/cubelet/s2.3-evidence/namespaces-20260831T151712Z`。

1. 默认 Pod：两个容器 net/IPC/UTS namespace 相同，PID/mount namespace 不同；
   hostname 精确为 Pod hostname，`/dev/shm` 在容器间共享，进程彼此不可见。
2. 共享 PID Pod：两个 workload PID 均大于 1；PID 1 为 `cube-pid-init`。具有
   `SYS_PTRACE` 的 alpha 验证 holder root 为空、仅有 `/dev/null` stdio FD、UID/GID
   为 65534、五类 capability 均为 0、NoNewPrivs=1、exe 为专用 helper；无
   `SYS_PTRACE` 的 beta 无法遍历 holder root。
3. alpha 被 SIGKILL 后 exit code 为 137；kubelet 以新 container ID 重建 alpha，旧
   Task/rootfs export 消失。beta、Pod UID/IP、Sandbox、Cube VM、shim PID、PID
   namespace 和 holder `(PID, comm, starttime)` 全部保持不变。
4. hostNetwork、hostPID、hostIPC 分别返回固定拒绝消息，没有 container ID 或 active
   lease，也没有创建 VM。
5. 两个成功 Sandbox 删除后，containers、Tasks、Sandboxes、overlay snapshots、netns、
   shim、reaper、VM runtime、mount 和 RuntimeResource 全部恢复 baseline；active lease
   为 0，durable tombstone 增量精确为 2。

```text
S23_DEFAULT_OK net_ipc_uts=shared pid=isolated mount=isolated hostname=ok shm=shared
S23_SHARED_PID_OK holder_pid1=ok holder_hardened=ok restart_join=ok survivor=ok
S23_HOST_NAMESPACE_REJECT_OK field=hostNetwork resources=baseline
S23_HOST_NAMESPACE_REJECT_OK field=hostPID resources=baseline
S23_HOST_NAMESPACE_REJECT_OK field=hostIPC resources=baseline
S23_NAMESPACES_OK shared_restart=ok host_rejections=3 active_leases=0 durable_tombstone_delta=2 vm_runtime=baseline
```
