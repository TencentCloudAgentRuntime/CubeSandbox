# Kubernetes runtime 与 AGC 合并验证

## 合并

- 集成分支：`integrate/kubernetes-runtime-agc`，提交 `4a358375`。
- 父提交：runtime `ff1b43f0`、AGC `dc1d3ae5`。
- 实现 tree：`a66632b7a6af7cd7f16ec7d5366050ea24d582d1`。
- 保留 CRI/S3 与 AGC 检查点接口；重新生成 Cubebox protobuf，保留 DNS 策略及指定 IP 恢复。
- 销毁先等待运行时退出，再释放 EROX 挂载；保留可选 hostNetwork，EgressProxy 启用时校验其依赖。
- 新增卷插件由源码构建，移除提交的二进制；统一组件标签并修正升级文档的网络前提。

## 本地验证

- `task build`、原生 Cubelet/CLI/两个卷插件构建通过。
- Go 定向测试：17 个包通过，5 个包无测试；包括网络、资源租约、卷、创建及快照恢复。
- Shim：298 项隔离单测通过；另外两项时序用例单独复测通过，合计覆盖 300 项。
- worker 真实进程测试通过；一个子进程辅助入口按框架设计忽略。
- Rust 格式、差异空白检查及 EgressProxy hostNetwork 正反向渲染检查通过。

已知限制：

- 两个 ICMP 单测 `TestProbeTimeoutMsWithPing`、`TestProbeConcurrentMixed` 在未合并 runtime 基线同样失败，定向回归将其排除。
- AGC 原分支的 `test-big-pod-inplace-guard.sh`、`test-egress-proxy-guard.sh` 同样失败；后者缺少预期的 `CUBE_ROUTER_ENABLE` 配置注入。
- 镜像版本检查将 Kubernetes/Helm 版本误判为 Cube 镜像标签，runtime 原分支可复现。
- `go vet` 报告既有 `pause_package.go` 及其测试复制 protobuf 锁字段；这两个文件未被合并修改。
- Egress veth 实测未通过本机构建容器的工具依赖检查，不能声明该路径已验收。

## 集群回归

已构建并推送安装镜像：`ccr.ccs.tencentyun.com/journeyyou/cube-cri-installer@sha256:bdd2f351f0963fb55263c553adb3d7687d2f6d33562cceaedee8ce75fe2f64a7`。尚未部署到节点。

尚未执行。计划在 TS4 节点 `10.0.244.89` 部署，使用 `10.0.244.2` 作 runc 对照，独立命名空间为 `cube-merge-agc-20260907`。

目标节点持续出现另一轮 Sonobuoy 任务，需待其释放或明确分配节点后再替换运行时。

```bash
UTILITY_IMAGE=mirror.ccs.tencentyun.com/library/busybox:1.36.1 \
  task test:e2e-framework -- \
  --cube-node 10.0.244.89 --runc-node 10.0.244.2 \
  --namespace cube-merge-agc-20260907
```

该框架含 15 项：探针 4、20 Pod 并发 1、基础语义 4、混合运行时 5、AWV CSI 1；不覆盖 Cubebox 组合检查点的集群恢复。

本地日志、制品哈希和部署前快照保存于集成 worktree 的 `_output/merge-agc/`。
