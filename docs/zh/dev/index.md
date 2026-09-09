# 开发者文档

本章节面向**在 CubeSandbox 代码库上工作**的工程师——贡献者、维护者，以及内部服务（CubeMaster、CubeProxy、CubeAPI、Cubelet）的集成者。这里汇集了安全改动系统所需遵循的约定、契约与内部参考。

如果你是*使用* CubeSandbox（部署、制作模板、调用 API），建议从[指南](../guide/introduction)开始。[架构](../architecture/overview)章节讲解系统设计；本章节则更深入一层，聚焦代码编写与服务协作所遵循的规则。

## 总体设计

- [CubeSandbox 对接 Kubernetes RuntimeClass 总体技术方案](./kubernetes-runtime-integration)——定义 Sandbox API/Task API 主架构、OCI rootfs、多容器、网络、存储、安全、恢复、测试以及二期快照设计。
- [Kubernetes RuntimeClass PoC 开发计划](./kubernetes-runtime-integration-development)——按 S0～S6 拆分实现目标、验收标准、代码组织、handoff 和未决问题记录方式。
- [Cube CRI 复用现有 Template 的一秒启动方案](./kubernetes-runtime-template-fastpath-s6.2)——模板全生命周期、Pod 复用条件与生命周期、CRI 快路径改造及验收。
- [Cube CRI 运行时监控方案](./cube-cri-observability)——定义内部指标、Shim 上报、Prometheus 采集、看板、告警和实施验收。

## 约定

- [Redis Key 命名规范](./redis-key-spec)——所有服务在共享 Redis 实例上必须遵循的统一命名空间：命名格式、归属划分、已注册 Key 清单、TTL 策略，以及各服务的 key 构造模块。

## 适合放在这里的内容

- 跨服务的数据契约与命名约定（key、消息主题、schema）
- 内部模块边界与新增行为的入口（如 key 构造、缓存层）
- 针对内部服务的编码规范与贡献规则
- 预留未来补充：内部 API、测试约定、贡献指南

::: tip 双语同步
开发者文档通常同时维护英文（`docs/dev/`）与中文（`docs/zh/dev/`）。本次 Kubernetes RuntimeClass 方案按评审要求只提供中文版本；其他新增或修改页面仍应保持两语言同步，并使用相同文件名以保证 URL 对齐。
:::
