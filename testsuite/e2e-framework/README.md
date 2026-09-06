# Cube CRI e2e-framework 测试

迁移自 `agc-cubesandbox-beta/testsuite/e2e-framework`，保留 15 个用例：探针 4 个、20 Pod 并发启动 1 个、基础语义 4 个、cube/runc 混跑 5 个、AWV CSI 跨运行时读写 1 个。

从仓库根目录运行（自动加载 `local.env`，可用 `CUBE_CRI_ENV` 指定配置文件）：

```bash
UTILITY_IMAGE=mirror.ccs.tencentyun.com/library/busybox:1.36.1 \
  task test:e2e-framework -- --cube-node 10.0.244.112 --runc-node 10.0.244.2
```

目标 cube 节点须已部署运行时并使用 TS4；省略 `--cube-node` 时选择带 `cubesandbox.io/runtime=cube` 标签的可调度 Ready TS4 节点。`--runc-node` 指定另一台物理节点；AWV CSI 用例要求两台节点均已部署对应 CSI 插件和 `awv-btrfs` StorageClass。

privileged 正向用例要求节点已配置 `CUBE_ALLOW_PRIVILEGED=true`，当前部署脚本默认开启；旧节点需更新配置，测试本身不修改开关。框架遇到致命断言会中止同组剩余用例，可通过 `--assess` 单独补跑。

```bash
task test:e2e-framework -- --probe-only --cube-node 10.0.244.112
task test:e2e-framework -- --feature runtime --cube-node 10.0.244.112
task test:e2e-framework -- --feature probe --assess 'http|tcp' --cube-node 10.0.244.112
task test:e2e-framework -- --help
```

默认在 `default` 命名空间运行并清理测试资源；`--namespace` 指定已存在的命名空间，`--keep` 保留资源用于排查。每次执行禁用 Go 测试缓存，整体超时默认 30 分钟。

镜像可用 `UTILITY_IMAGE` 和 `CUBE_IMAGE` 覆盖；工具镜像须包含 `/bin/sh`、`httpd`、`sleep` 等 BusyBox 命令。当前 cube 运行时拒绝 `hostNetwork`，因此 cube Pod 改用标准 Pod 网络，runc 宿主机检查沿用原设置。缺少 StorageClass 或第二台物理节点会跳过对应用例，跳过不代表通过。
