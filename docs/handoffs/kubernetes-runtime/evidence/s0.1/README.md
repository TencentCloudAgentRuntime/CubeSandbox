# S0.1 原始证据

- 验证实现：`33dbf479`（包含 `6a53a52d` 的 socket 清理修复）。
- 完整重放：腾讯云 TAT `inv-68246d0jt1`，状态 `SUCCESS`、exit code 0。
- 导出任务：TAT `inv-b82470gjb6`；导出归档 SHA-256
  `421b80f835266f76ffe4e556502498760edb68025f8b39544cc2cc1c0cc596b8`。
- `s0.1-summary.txt` 是脚本断言摘要；`*-shim.jsonl`、`*-cni.jsonl` 和
  `*-runp.txt` 是该次运行未经改写的输出。

- [断言摘要](./s0.1-summary.txt)
- 正常链路：`s0.1-normal-shim.jsonl`、`s0.1-normal-cni.jsonl`
- Create 失败：`s0.1-fail-create-shim.jsonl`、`s0.1-fail-create-cni.jsonl`、[runp](./s0.1-fail-create-runp.txt)
- Start 失败：`s0.1-fail-start-shim.jsonl`、`s0.1-fail-start-cni.jsonl`、[runp](./s0.1-fail-start-runp.txt)
- shim crash：`s0.1-crash-create-shim.jsonl`、`s0.1-crash-create-cni.jsonl`、[runp](./s0.1-crash-create-runp.txt)
- 客户端取消：`s0.1-cancel-create-shim.jsonl`、`s0.1-cancel-create-cni.jsonl`、[runp](./s0.1-cancel-create-runp.txt)

重放命令：

```bash
cd CubeShim/sandbox-probe
sudo scripts/verify-cloud.sh
```

旧探针曾留下两个不可连接 socket；本次运行前逐一验证不可连接后删除。此后正常链路和
四种异常用例均由脚本断言 socket 及其余九类资源为零。
