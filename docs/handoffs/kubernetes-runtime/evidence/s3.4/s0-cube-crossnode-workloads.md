# S0 Cube RuntimeClass 跨节点 HTTP/curl 验证环境

日期：2026-09-02。S0 三节点自建 Kubernetes 集群现已把两个工作节点配置为
Cube runtime 节点，并保留 5 副本 Deployment、3 副本 StatefulSet 供人工验证。
控制节点不运行 Cube Pod；一个 Pod 对应一个 Cube VM，Pod 内 nginx 与 curl 两个
容器共享该 VM 和网络。

## 固定环境

| 项目 | 值 |
|---|---|
| Kubernetes / containerd / Cilium | `v1.36.4` / `2.3.4` / `1.20.0` |
| 控制节点 | `ins-qj8d7ypa` / `cubesandbox-s0-control` / `172.19.200.7` |
| Cube 工作节点 1 | `ins-li9gprdw` / `cubesandbox-s0-worker` / `172.19.200.12` |
| Cube 工作节点 2 | `ins-4dyul5ag` / `vm-200-13-ubuntu` / `172.19.200.13` |
| 工作节点内核 | `6.6.69-opencloudos9.cubesandbox.pvm.host-g0de43d6b3bcd`，KVM/PVM |
| namespace / RuntimeClass | `cubesandbox-cube-crossnode` / `cube` |
| 调度 | 两个工作节点分别 3/5 个 Pod；硬性 `minDomains: 2` |

清单位于
[`deploy/kubernetes/smoke/multinode-http-cube.yaml`](../../../../../deploy/kubernetes/smoke/multinode-http-cube.yaml)，
提交为 `c46f38d4`，SHA-256 为
`1fddd18375d10cdc50211e9b2e46832d624a1aacafe77cc3da6887fdf1b07b07`。
每个 Pod 的 curl readiness 同时检查 localhost 和 Kubernetes Service DNS；StatefulSet
额外检查 `stateful-http-0.stateful-http`。

## 运行时修正和制品

首次并发拉起 8 个 Cube Pod 暴露三个真实前置条件：

- 缺失 `/data/log/CubeVmm` 会令 VMM logger panic；`ea441201` 改为 VMM 启动时创建父目录。
- 多 Sandbox 并发创建 `socket-locks` 会发生 `create_dir_all` 的 TOCTOU；同一提交改为
  并发安全、重验目录类型并 fsync。
- Sandbox DNS 已进入 Guest，但 containerd `sandboxer=shim` 不一定给 workload OCI
  注入 resolver mount。Agent 写出的 resolver 又受 umask 影响。`ea441201` 将源文件固定为
  `0644`；`2269a3b3` 仅在 managed task 没有显式 resolver 时，在 Host bind export 完成后
  注入 Guest `/etc/resolv.conf` 的只读 bind。显式 mount 保持，legacy 路径不变。

最终构建 `inv-0863q50pvw`、摘要 `inv-b8643a0v9s` 均为 `SUCCESS`：standard-rootfs
20/20，缺失注入与显式保留两项专项测试通过，release 构建完成。最终制品为：

| 制品 | SHA-256 |
|---|---|
| CubeShim | `9cfaf6d31eb0c394fc3bba161d9edb6ea03436c8f2b3e79a80f25b20d48fe6be` |
| Agent ext4 | `870fd590268333ab16e05ef1e900b82b07432ea0d92a5df86182d7d042522b76` |
| runtime 归档（13,579,201 字节） | `4aeefc91cce8252b4343c3b730fccb56840e8756d2580b85682f708c7c871345` |

私有 COS 对象为
`poc/s0-cube-multinode/runtime/runtime-2269a3b3.tar.gz`；两个节点的安装任务
`inv-6863vkgfv3`、`inv-8863vm0htp` 均完成下载/内部 SHA 校验、版本目录切换和四项服务恢复。
旧版本目录和配置副本仍保留，可回滚。`inv-0863uwgsgk` 另确认 worker1 在预先移走
`/data/log/CubeVmm` 后由新 VMM 自动重建该目录。

同一 reviewer 对启动前置修正和 DNS 增量分别给出 P0=0、P1=0、`APPROVE`。本地
Shim lib check 通过；本机测试只因缺少 `libseccomp` 停在链接，真实链接和测试以上述
云端构建为准。

## 最终验收

`inv-8863x002rx` 在 9 秒内完成最终 rollout：Deployment `5/5`、StatefulSet `3/3`，
8 个 Pod 均为 `2/2 Running`、重启数 0。

| TAT invocation | 结论 |
|---|---|
| `inv-8863xngiss` | 8 Pod、2 节点；PodIP 全互访 64/64，其中跨节点 30/30；稳定 DNS 24/24；ClusterIP 24/24 |
| `inv-38640k0ru9` | worker1：3 个 CRI Pod = 3 个 `io.containerd.cube.rs` sandbox = 3 个 VM/active lease/adapter；锁竞态或 panic 为 0 |
| `inv-88640n0hs5` | worker2：5 个 CRI Pod = 5 个 `io.containerd.cube.rs` sandbox = 5 个 VM/active lease/adapter；锁竞态或 panic 为 0 |
| `inv-98642mgspg` | 8 个 uid 100 sidecar 均读取 `0644` resolver、解析完整集群域名并访问 API Service；uid 0 写入全部因只读 mount 失败 |
| `inv-88646d02fx` | 8 个 Pod 最近 40 次周期 curl 无 `failed`，全部持续 Ready |

切换前两次均先缩容到 0；`inv-0863uwgsgk`、`inv-v863uvg0dm` 证明 active lease、VM、
adapter 全部为 0 后才替换运行时。最终按用户要求保留 8 个 Pod 运行，因此 3/5 个活动
VM/lease 是预期现场状态，不是残留。

诊断过程中的 `inv-8863g4g18m` 明确记录了修复前 resolver 为镜像自带的空 `0700`
文件，而 Service IP 直连已返回 403，故障归因于 resolver 继承而非 Cilium 数据面。
`inv-886417g92c` 是只读断言的 shell 重定向写法错误；`inv-b8641k0cnf` 使用了 BusyBox
`nslookup` 不扩展 search domain 的短名称。最终 `inv-98642mgspg` 改用完整集群域名并由
root 验证只读挂载，替代这两次脚本失败。

## 人工复查

登录控制节点后使用 `/etc/kubernetes/admin.conf`：

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl -n cubesandbox-cube-crossnode get pods -o wide
kubectl -n cubesandbox-cube-crossnode logs stateful-http-1 -c curl --tail=5
kubectl -n cubesandbox-cube-crossnode exec stateful-http-1 -c curl -- \
  curl -fsS http://stateful-http-0.stateful-http/
kubectl -n cubesandbox-cube-crossnode exec stateful-http-1 -c curl -- \
  curl -fsS http://deployment-http/
```

低层身份需在对应工作节点查看：

```bash
ctr -n k8s.io sandboxes list
find /run/vc/vm -mindepth 1 -maxdepth 1
```

本环境完成跨节点 Cube workload 回归，但不替代 S3.4c.2 尚未完成的 sibling/PID 诱饵、
containerd restart 和 legacy Task 验收，因此 Stage 状态仍为 `VALIDATING`。
