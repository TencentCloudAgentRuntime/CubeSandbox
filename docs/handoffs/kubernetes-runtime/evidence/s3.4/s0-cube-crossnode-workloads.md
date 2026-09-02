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

### 补齐 `cube-runtime` CLI（2026-09-03）

最初的 S0 增量运行包只包含本轮需要替换的 CubeShim 和 Agent，没有包含 Host 侧调试/
snapshot 辅助 CLI `cube-runtime`。这不影响 containerd 通过
`containerd-shim-cube-rs` 启动 Pod，但不满足人工使用 `cube-runtime login` 或底层
snapshot 命令的需要。

补充构建从 `2269a3b3248bda1259cec722fbdd1d20cf843bbd` 精确归档 `CubeShim/` 与其
同仓 `hypervisor/` path dependency。源码归档共 1,622,355 字节，SHA-256 为
`46a80b5ec919326d4740b3fef7cc7d5f5a439d72a78bfaa9a73f062eef85d80f`，私有 COS
对象为 `poc/s0-cube-multinode/source/CubeSandbox-buildsrc-2269a3b3.tar.gz`。
构建任务 `inv-886aawg8bb` 在 build CVM 的既有 Docker builder 中完成；其编译日志超过
TAT 24 KiB 输出上限，但任务本身为 `SUCCESS`，随后 `inv-v86aeig4w1` 独立读取产物身份：

| 项目 | 值 |
|---|---|
| `cube-runtime` 版本 | `0.0.0-s0-k8s-poc (2269a3b3248bda1259cec722fbdd1d20cf843bbd)` |
| 文件大小 | 9,381,472 字节 |
| SHA-256 | `8c17375d937bf612e617d9a98c0ccfdf551a8916197b9cf103f64b3c00aa41ec` |
| 私有 COS 对象 | `poc/s0-cube-multinode/runtime/cube-runtime-2269a3b3` |

`inv-v86aek0p10` 在两个 Worker 上均先校验下载 SHA，再写入
`/opt/cubesandbox-s0-multinode-runtime-2269a3b3/bin/cube-runtime`，更新该版本的
`SHA256SUMS`，并创建 `/usr/local/bin/cube-runtime` 软链接。旧 manifest 保存在各节点的
`backups/SHA256SUMS.pre-cube-runtime-20260903`。两个节点的 `--version`、`login --help`
和 `snapshot --help` 均通过，containerd 没有重启且保持 `active`；活动 sandbox/VM 数量
仍分别为 3/3 和 5/5。`inv-v86aem0qtx` 随后确认 8/8 Pod Ready、重启数 0，并从每个
Pod 访问 Service DNS，结果 8/8。
独立只读审计 `inv-886ag30i7c` 又在两个 Worker 上执行完整 `sha256sum -c
SHA256SUMS`，Shim、harness、Agent、kernel、guest image 与新增 CLI 全部为 `OK`；同时复核
软链接目标、manifest 备份、两个 CLI 子命令和 containerd `active`。

构建前的失败尝试都发生在隔离 build CVM 目录、早于 Worker 安装：`inv-b86a810mfs`
缺少非登录 shell 的 Cargo PATH，`inv-986a9dgnaq` 证明只归档 `CubeShim/` 会缺少
`hypervisor/` path dependency，`inv-v86aam052w` 是 builder 工作目录指向源码根而非
`CubeShim/`。三者均未修改 Worker；相关隔离目录保留用于审计。

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
cube-runtime --version
cube-runtime login --help
cube-runtime snapshot --help
ctr -n k8s.io sandboxes list
find /run/vc/vm -mindepth 1 -maxdepth 1
```

本环境完成跨节点 Cube workload 回归。其后 S3.4c.2 的 sibling/PID 诱饵、containerd restart
和 legacy Task 验收已另行完成；用户于 2026-09-03 验收后授权删除本页的 Deployment、
StatefulSet 及 8 个 Pod，namespace 与 RuntimeClass 保留。当前状态与终验见
[`s3.4c.2-execution-summary.md`](./s3.4c.2-execution-summary.md)。
