# Coding Agent Runtime 基准

本目录只编排、隔离和采集；唯一 Agent 是发布版 Pi，不含自研模型循环或工具实现。

## 当前锁定

`T_AGENT_TEST_PLAN.md` 定义 Cube/runc 的 `t_agent` 方案；`task-matrix.t-agent.json` 是唯一候选任务清单。候选来自构建/调试、系统运维和安全三类终端操作密集型任务；不含 SWE、GPU 训练、纯推理或纯数据任务。

## 文件职责

- `build-terminal-image.sh`：构建单个 Terminal-Bench 任务镜像，叠加发布版 Pi 与验证缓存，并导入目标节点。
- `run-terminal-case.sh`：执行单次 runc 或 Cube case，记录 `t_agent`、验证结果和 Pod/事件工件。
- `run-terminal-formal.sh`：按固定顺序执行每任务 6 个 runc/Cube 配对，并生成正式汇总。
- `run-terminal-suite.sh`：一键执行已验收的 9 个 formal 任务，自动构建镜像、运行配对、补跑未配对样本、清理节点镜像并生成 suite 汇总。
- `scripts/agent-run.sh`、`scripts/run-terminal-agent.sh`：只启动发布版 Pi 并记录外层时间，不实现 Agent 循环。
- `scripts/verify-terminal.sh`、`scripts/verifier-*.sh`：原样调用任务验证入口，仅把固定依赖下载替换为镜像缓存。
- `scripts/extract-instruction.py`、`scripts/sanitize-pi.py`、`scripts/sample-resources.py`、`scripts/summarize-*.py`：读取任务指令、脱敏事件、采样资源和离线汇总。

`build-terminal-image.sh` 的 apt/PyPI mirror 参数只用于外层临时 build context；启用后必须以 `image-manifest.json` 记录，不能修改 Terminal-Bench 原始任务目录。

## 隔离口径

- 每次由不可变任务镜像复制 `/app` 到新的 `emptyDir`；Pi session 不复用。
- Pi 容器仅挂载 instruction、workspace、artifacts 和 Secret；不挂载 tests。
- Pi 写入 `agent.done` 后才加载上游 tests，并在同一 Agent 容器运行未改动的 `run-tests.sh`。
- 原 runner 的固定 uv 与验证依赖使用有 SHA-256 的镜像缓存；验证耗时只作成功判定和诊断，不并入 `t_agent`。

## 样本判定

正式轮次仅在同任务、同轮 runc/Cube 均通过原始验证时进入配对时延统计。Pi JSON 事件在写盘前流式脱敏；采集 `responseId`、token、工具调用、资源 cgroup 样本及 Pod 快照。

## 当前状态

- 早期 `fix-permissions` 单任务旧方案已清理；当前只保留 Terminal-Bench 终端密集型任务矩阵。
- 套件级入口：`task test:coding-agent:formal -- --node 172.17.209.85 --task-root /data/home/journeyyou/agc37-cache/terminal-bench-d28711d/terminal-bench/original-tasks`。
