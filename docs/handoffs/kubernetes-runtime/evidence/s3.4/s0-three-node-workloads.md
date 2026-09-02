# S0 三节点自建集群 HTTP/curl workload

日期：2026-09-02。按用户要求，将多节点 HTTP/curl 清单部署到 S0 三节点自建
Kubernetes 集群。该集群尚未配置 Cube RuntimeClass/containerd handler，因此本次结果
是默认 containerd runtime 的三节点基线，不作为 CubeSandbox 运行时验收证据。

## 环境和工作负载

| 项目 | 值 |
|---|---|
| Kubernetes / containerd | `v1.36.4` / `2.3.4` |
| 控制节点 | `ins-qj8d7ypa` / `cubesandbox-s0-control` / `172.19.200.7` |
| 工作节点 1 | `ins-li9gprdw` / `cubesandbox-s0-worker` / `172.19.200.12` |
| 工作节点 2 | `ins-4dyul5ag` / `vm-200-13-ubuntu` / `172.19.200.13` |
| namespace | `cubesandbox-extra-smoke` |
| Deployment | `deployment-http`，5 个 Pod |
| StatefulSet | `stateful-http`，3 个 Pod |

三台节点均为 `Ready`。清单复用
[`deploy/kubernetes/smoke/multinode-http.yaml`](../../../../../deploy/kubernetes/smoke/multinode-http.yaml)，
提交为 `e060be74`，SHA-256 为
`5d643448d98ff523856c1a644df47bd3fed485d74fa4237efd972b3b1f92e7f1`。
每个 Pod 包含 nginx HTTP server 与 curl sidecar；StatefulSet 通过 headless Service
提供稳定 DNS。

## 执行和故障处理

| TAT invocation | 结果 |
|---|---|
| `inv-v860epgpsd` | apply、rollout 和全部 Pod Ready 成功，最终 Deployment `5/5`、StatefulSet `3/3` |
| `inv-v860hq0q2s` | 从控制节点导出两个已缓存 OCI 镜像并上传私有 COS，归档 30,417,920 字节 |
| `inv-3860i8g3c0` | 第三节点下载、校验并导入镜像成功 |
| `inv-0860it04kv` | 仅重建第三节点上受镜像退避影响的 3 个测试 Pod |
| `inv-0860m609a2` | 重启第三节点 containerd，取消陈旧的 Docker Hub 拉取请求，服务恢复 `active` |
| `inv-b860n808vc` | 应用层全量验收成功，输出 `S0_MULTINODE_SMOKE_OK` |

第三节点访问 Docker Hub 首次发生 HTTPS timeout。为避免依赖不稳定公网，使用本 PoC
私有 COS 对象 `poc/s0/workload-images-20260902.tar` 中转镜像；归档 SHA-256 为
`b818cec05cb7702779d0fc00307314e303a8e1a6966b834dd14a7020f890b0bb`，下载后校验通过。
未修改其他账号资源。

## 验收结论

- 8 个 Pod 均为 `2/2 Running`，容器重启次数为 0；
- Pod 覆盖全部 3 个节点：控制节点 `1 Deployment + 1 StatefulSet`，工作节点 1
  为 `2 + 1`，工作节点 2 为 `2 + 1`；
- 5 个 Deployment Pod 的 localhost 与 ClusterIP Service HTTP 请求全部成功；
- 3 个 StatefulSet Pod 的 localhost、`stateful-http-0.stateful-http` 稳定 DNS 与
  Deployment Service HTTP 请求全部成功；
- 8 个 curl sidecar 最后一条周期日志均以 `curl-ok` 开头且不含 `failed`；
- Deployment 为 `desired=5 ready=5 available=5`，StatefulSet 为
  `desired=3 ready=3 current=3`；
- 所有 Pod 的 `.spec.runtimeClassName` 均为空，验收标记明确记录
  `runtime=default-containerd`。

## 复查命令

在控制节点使用 `/etc/kubernetes/admin.conf`：

```bash
kubectl -n cubesandbox-extra-smoke get pods -o wide
kubectl -n cubesandbox-extra-smoke logs stateful-http-1 -c curl --tail=5
kubectl -n cubesandbox-extra-smoke exec stateful-http-1 -c curl -- \
  curl -fsS http://stateful-http-0.stateful-http/
kubectl -n cubesandbox-extra-smoke exec stateful-http-1 -c curl -- \
  curl -fsS http://deployment-http/
```
