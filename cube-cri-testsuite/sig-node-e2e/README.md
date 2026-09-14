# SIG Node e2e Skip 列表

本目录维护 Cube CRI 运行 Kubernetes SIG Node e2e 时的默认 skip 列表。目标是把已确认的环境噪声和当前明确不支持的语义从日常巡检中剥离出来，让真实 Cube CRI 回归更容易暴露。

## 文件

- `skip-list.json`：唯一维护入口。每个启用条目必须包含 `pattern`、`reason`、`source` 和 `exitCriteria`。
- `render-skip.py`：校验列表并生成 `--ginkgo.skip` 正则。
- `run.sh`：运行 `e2e_node.test` 的轻量封装，自动合并基础 skip、仓库 skip 列表和额外 skip。

## 使用

```bash
python3 cube-cri-testsuite/sig-node-e2e/render-skip.py --format arg

E2E_NODE_TEST=/path/to/e2e_node.test \
KUBECONFIG=~/.kube/dev-cls-config-sh-cube-cri \
task test:sig-node-e2e
```

需要临时追加 skip 时，使用环境变量，不要直接改命令行里的长正则：

```bash
SIG_NODE_E2E_EXTRA_SKIP='some focused temporary regex' task test:sig-node-e2e
```

`run.sh` 会在输出目录保存本轮实际使用的 `ginkgo-skip.regex` 和渲染后的 `skip-list.md`，便于复盘。

## 维护原则

- 只跳过已分类的问题；不要把未定位失败加入列表。
- `reason` 说明为什么现在要跳过，`exitCriteria` 说明什么时候必须移除。
- Cube CRI 真实疑似缺陷不进入默认 skip。AGC-39 中的 `Pods Extended Pod Container lifecycle evicted pods should be terminal` 已拆到 AGC-41 跟进，因此默认不跳过。
- 环境类 skip 应优先收敛环境。镜像、DRA、节点拓扑修好后，应删除对应条目并复测。
