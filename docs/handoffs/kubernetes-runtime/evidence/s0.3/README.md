# S0.3 CNI 网络探针证据

## 结论

- 结果：`SUCCESS`。标准 OCI BusyBox 容器在 Cube VM 中复用 Cilium 分配给 anchor Pod 的 netns、IP、MAC、MTU、路由和 DNS。
- 已验证：Pod IP 等于 Cube VM IP、跨节点 PodIP、Cluster DNS、Service ClusterIP、Cilium egress NetworkPolicy，以及失败/成功后的零残留清理。
- 选型：PoC 首选 Cilium 1.20.0 + tcfilter；VPC-CNI 与 Global Router 保留为 S1 之后的网络 adapter 兼容项，不用它们阻塞当前架构。

## 环境

| 项目 | 值 |
|---|---|
| 隔离验收节点 | `ins-4dyul5ag` / `cubesandbox-k8s-poc-s0-pvm66-hk2（勿删）`，16C32G，100G |
| Kubernetes | `v1.36.4`，3 个节点最终均 `Ready` |
| containerd | `v2.3.4` |
| CNI | Cilium `v1.20.0` |
| PVM Host/Guest | Host `6.6.69-opencloudos9.cubesandbox.pvm.host-*`，Guest `6.6.69` |
| runtime binary | SHA-256 `4414ee5da24871978b65a34a04a2999430169b91e0f18f1163b90e14d6d43a10` |

## S0 实现边界

- `io.containerd.cube.s0.cni-netns=<absolute path>` 只为 S0 探针显式启用；相对路径在 VM 创建前失败，并验证 rootfs、shim、Task、Container 均清理。
- anchor Pod 只在 S0 保存 CNI netns。探针在 Pod netns 创建 TAP 与双向 tc ingress redirect；CubeShim 在专用线程中 `setns`、打开 TAP、设置 vnet header/offload 后把 FD 传给嵌入式 VMM。
- VMM 通过 `fds_from_other_netns` 明确区分跨 netns FD，跳过不可见接口的 name-based ioctl；跨 netns 路径关闭 virtio/TAP offload，避免 checksum/segmentation 元数据进入 tc 路径。
- Pod MAC 与 MTU 必须通过目标 netns 的 netlink 读取。只切换 network namespace 后读取宿主机 sysfs 会误取 CVM eth0 MAC；本探针已改用 `ip -j link` 并有 MAC/MTU 回归断言。
- 容器继续使用 S0.2 的标准 `CreateTaskRequest.rootfs` 适配。DNS 同时传入 sandbox DNS，并通过 Cubelet 已有 `cube.container.custom.file` 机制注入容器 `/etc/resolv.conf`，对应后续 CRI 的 Pod DNS 文件注入。
- S1 必须由 containerd Sandbox Service/Cubelet network adapter 提供 netns 与 attachment，删除 anchor Pod 和两个 S0 annotation 开关。

## 可复现证据

| 验证 | TAT invocation | 结果 |
|---|---|---|
| release 构建与 74 项测试 | `inv-982ekw0q2u` | `SUCCESS`；产物哈希与最终运行一致 |
| 本地完整 workspace 测试 | `make shim-test` | `SUCCESS`；CubeShim 74 项、cube-runtime 1 项，0 失败 |
| 匹配 PVM66 的无网络对照 | `inv-b82fadg4xe` | `SUCCESS`；标准 OCI rootfs、动态 bind/rename/只读、卸载和零残留通过 |
| Cilium anchor 原生网络对照 | `inv-b82g3a0mda` | `SUCCESS`；DNS、ClusterIP、跨节点 PodIP 通过，策略禁止目标超时 |
| Cube 完整 CNI 验收 | `inv-a82g9g0x1f` / task `invt-a82g9g0x1g` | `SUCCESS` |
| 最终集群与 namespace 检查 | `inv-682gcjgsnu` | `SUCCESS`；3 节点 Ready，`cube-s0-net` 不存在 |
| 临时传输材料清理 | `inv-a82gjx0qs1`、`inv-082gk10fhb` | `SUCCESS`；仅清理本任务临时 HTTP/SSH/kubeconfig 材料，CVM 与集群保留 |

完整 CNI 验收的关键标记：

- `S0_3_CREATE_FAILURE_CLEAN_OK`
- `POD_IP_EQUALS_CUBE_VM`
- `CLUSTER_DNS_OK`
- `SERVICE_CLUSTER_IP_OK`
- `CROSS_NODE_POD_TO_POD_OK`
- `NETWORK_POLICY_DENY_OK`
- `RESIDUE tasks=0 containers=0 shims=0 taps=0 source_filters=0 tap_filters=0 rootfs_mounts=0 rootfs_dir=0`
- `KUBERNETES_CNI_NAMESPACE_CLEAN`
- `S0_3_CNI_PROBE_OK`
- `S03_PVM66_FULL_CNI_ACCEPTANCE_OK`

仓库重放入口：

```bash
cd CubeShim
KUBECONFIG=/etc/kubernetes/admin.conf \
SOURCE_NODE_IP=<cube-node-ip> \
PEER_NODE_IP=<peer-node-ip> \
ADDRESS=/run/containerd-cube-s0.3/containerd.sock \
NAMESPACE=s0-3 \
./s0-cni-probe/run.sh
```

脚本自行创建和删除 `cube-s0-net` namespace、测试 Pod、Service、NetworkPolicy、TAP、tc filter 和隔离 containerd；退出时再次断言所有 S0.3 资源为零。

## 诊断结论与限制

- Host 6.12/Guest 6.6 的有网和无网对照均在 VM reset 阶段失败；匹配 Host/Guest 6.6.69 后无网络对照与完整网络用例均成功，因此该问题归为 PVM Host/Guest 兼容性，而非 CNI 代码。
- S0 只证明 Cilium tcfilter 路径。VPC-CNI 与 Global Router 需要各自 adapter/E2E，不改变一个 Pod IP 对应一个 Cube VM 的接口边界。
- 跨 netns FD 路径暂时禁用网络 offload，性能基线与按能力恢复 offload 留到 S5。
- 嵌入式 VMM 的 seccomp 为 shim rootfs 清理增加最小 `umount2`；这是 PoC 清理闭环的已记录权衡，生产权限拆分不属于 S0 验收。
