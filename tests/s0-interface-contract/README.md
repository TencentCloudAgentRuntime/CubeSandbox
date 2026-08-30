# S0.4 组件接口契约探针

该探针冻结两条边界：

- CubeShim 到 Cubelet 使用 `runtime.v1.RuntimeResource`，只包含 capability、Prepare、Release、Inspect 和 report-only Reconcile；OCI image/snapshot、CRI Sandbox/Task 和 CNI 调用顺序仍由宿主 containerd 管理。
- CubeShim 到 Guest Agent 复用兼容的 `Health.Version`，在原字段 1、2 后追加 protocol version 与版本化 capability 列表。旧 Agent 返回字段默认值时继续服务 legacy Cubebox；S1 的 Kubernetes handler 必须明确校验所需 capability。

控制面使用 Cubelet gRPC Unix socket。TAP 文件描述符不进入 protobuf，继续通过现有 cubetap Unix socket和 `SCM_RIGHTS` 一次性交付。

运行：

```bash
./tests/s0-interface-contract/run.sh
```

Rust 检查默认在 builder 镜像中执行，自动选择 Docker 或 containerd `ctr`；可用 `CUBE_BUILDER_RUNNER`、`CUBE_BUILDER_IMAGE` 覆盖。已准备等价依赖的环境可设置 `S0_4_RUST_TEST_MODE=native`。

脚本验证 proto 副本同步、禁止 runtime/v1 暴露递归 containerd/CRI 方法、Go descriptor 契约、CubeShim capability 解析与 Agent capability 响应。
