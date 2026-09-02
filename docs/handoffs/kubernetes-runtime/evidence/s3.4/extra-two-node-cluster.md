# 额外两节点 TKE HTTP/curl 验证集群

日期：2026-09-02。该环境用于用户交互验证和后续多节点基线，不作为 Cube
RuntimeClass 能力验收；当前工作负载使用 TKE 默认 containerd runtime。

## 资源清单

| 资源 | 值 |
|---|---|
| TKE | `cls-1oqe2py4` / `cubesandbox-k8s-poc-extra-2n（勿删）` |
| Kubernetes | `1.36.2-tke.1`，托管控制面，Global Router |
| 节点 1 | `ins-h06xpkbw` / `cubesandbox-k8s-poc-extra-tke-worker（勿删）1`，`SA5.2XLARGE16`，`172.19.200.8` |
| 节点 2 | `ins-lus07026` / `cubesandbox-k8s-poc-extra-tke-worker（勿删）2`，`SA5.2XLARGE16`，`172.19.200.4` |
| 节点系统 | Ubuntu 24.04.4 LTS，Linux 6.8.0-124，containerd 2.2.5-tke.1 |
| 专属安全组 | `sg-e5gbvltd` / `cubesandbox-k8s-poc-extra-tke（勿删）` |
| 网络 | 复用 `vpc-1qdegf12` / `subnet-grai82cj`；Pod `10.253.0.0/16`，Service `10.254.0.0/20` |
| API | 内网 TLS endpoint `172.19.200.15` 已创建；公网 endpoint 未创建 |

两台节点均有公网出口用于拉取测试镜像，但安全组没有开放公网 SSH。账号 CAM
策略显式拒绝创建公网 TKE endpoint，因此改用允许的内网 TLS endpoint；这不阻塞
同 VPC CVM 和 TKE 控制台访问。以上资源均为本次 PoC 新建，名称带“勿删”，不得
与账号内既有 TKE/CVM 混淆或删除。

## 工作负载

清单位于 [`deploy/kubernetes/smoke/multinode-http.yaml`](../../../../../deploy/kubernetes/smoke/multinode-http.yaml)，
提交为 `e060be74`，SHA-256 为
`5d643448d98ff523856c1a644df47bd3fed485d74fa4237efd972b3b1f92e7f1`。

- namespace：`cubesandbox-extra-smoke`；
- `Deployment/deployment-http`：5 个 Pod；
- `StatefulSet/stateful-http`：3 个 Pod，使用 headless Service 提供稳定 DNS；
- 每个 Pod 包含 `nginx:1.27-alpine` HTTP server 和
  `curlimages/curl:8.10.1` curl sidecar；
- topology spread 使 8 个 Pod 同时覆盖两个节点；
- curl sidecar 周期访问本 Pod、Deployment Service；StatefulSet sidecar 还访问
  `stateful-http-0.stateful-http`。

## 验收证据

| TAT | 结果 |
|---|---|
| `inv-b85wheg33g` | 节点预检成功；两节点均 `Ready`，版本和 runtime 符合上表 |
| `inv-385wi100bq` | 清单 apply 与 rollout 成功；Deployment `5/5`、StatefulSet `3/3` |
| `inv-a85win0n3a` | 八个 Pod 的 localhost、Service、稳定 peer DNS 和 sidecar 日志全部通过，输出 `EXTRA_TKE_SMOKE_OK` |

最终分布为 Deployment `3+2`、StatefulSet `2+1`；所有 Pod `2/2 Running`、零重启。
每个 Pod 内显式 curl 均返回带目标 Pod/Node 身份的 HTTP 响应，Service 请求至少观察
到跨节点后端；curl sidecar 最后一条日志均无 `failed`。

## 用户验证

在任一集群节点或可达该 VPC 的主机上使用集群 kubeconfig：

```bash
kubectl -n cubesandbox-extra-smoke get pods -o wide
kubectl -n cubesandbox-extra-smoke logs stateful-http-1 -c curl --tail=5
kubectl -n cubesandbox-extra-smoke exec stateful-http-1 -c curl -- \
  curl -fsS http://stateful-http-0.stateful-http/
kubectl -n cubesandbox-extra-smoke exec stateful-http-1 -c curl -- \
  curl -fsS http://deployment-http/
```
