# Cube CRI Grafana IAC

`deploy/kubernetes/cube-cri-monitoring/monitoring.yaml` 由本目录生成，提供独立 Prometheus、Grafana、10Gi 数据 PVC 和 Cube CRI 节点发现配置。

```bash
go run ./cmd/grafanacfg
go run ./cmd/grafanacfg -check
go test ./...
```

面板按总览、Pod 创建路径、回收与节点状态、监控链路健康排列，只使用时序面板和 `rate()` 查询。
