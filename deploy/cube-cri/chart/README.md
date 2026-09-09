# Cube CRI Helm Chart

Chart 以两阶段标签管理节点：`agc.cloud.tencent.com/cube=true` 自动运行安装 DaemonSet；安装器通过 ServiceAccount 成功写入 `agc.cloud.tencent.com/cube-ready=true` 后，`RuntimeClass/cube` 才可调度到该节点。

安装镜像必须由现有构建流程生成，内含 `runtime.tar.gz` 和 `pvm-host.rpm`。请使用不可变 digest。

## 安装

首次纳管节点前确认其为 Ready 的 TS4 x86_64 节点，然后设置安装标签：

```bash
kubectl label node <node> agc.cloud.tencent.com/cube=true

helm upgrade --install cube-cri deploy/cube-cri/chart \
  --namespace cube-cri-system --create-namespace \
  --set image.repository=<registry>/cube-cri-installer \
  --set image.digest=<sha256的64位十六进制值> \
  --wait --timeout 30m

kubectl -n cube-cri-system rollout status daemonset/cube-cri-cube-cri --timeout=30m
kubectl get node <node> -L agc.cloud.tencent.com/cube-ready
```

`--wait` 是流程的一部分：安装器可能为 PVM 内核重启节点，DaemonSet Ready 前不会写入 ready 标签。后续扩容只需设置安装标签并等待 ready 标签出现。删除 DaemonSet 不卸载宿主机运行时或内核；节点退役时请先迁移或删除 Cube Pod，再同时移除 `cube` 与 `cube-ready` 标签。

如集群已有同名且未被 Helm 管理的 `RuntimeClass/cube`，先核对其 handler、overhead 和 nodeSelector 与本 Chart 一致，并在 Helm 命令中设置 `runtimeClass.enabled=false`；Chart 不接管该资源。

## 常用配置

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `nodeSelector` | `agc.cloud.tencent.com/cube=true` | 触发安装 DaemonSet 的节点标签选择器 |
| `runtimeClass.nodeSelector` | `agc.cloud.tencent.com/cube-ready=true` | RuntimeClass 的可调度节点标签选择器 |
| `image.repository` / `image.digest` | 必填 | 安装镜像仓库和 SHA-256 digest |
| `imagePullSecrets` | `[]` | 私有仓库拉取凭据 |
| `runtimeClass.name` | `cube` | 创建的 RuntimeClass 名称 |
| `runtimeClass.enabled` | `true` | 已有同名 RuntimeClass 时设为 `false` |
