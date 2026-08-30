# PoC Handoff 规则

适用于 Kubernetes RuntimeClass PoC。Stage 进度只记录在开发计划的 `Sx.x` 状态表：状态、Owner、已完成、验收证据和下一步；handoff 不复制进度表，只记录当前 `Sx.x`、基线 commit、最后一项验证、阻塞、受保护路径和接手动作。

暂停、换人或状态变化时，先更新对应 `Sx.x`，再更新 handoff 和未决问题表。结论必须能由命令、日志摘要或演示复现；代码合入但未通过验收只能标记 `VALIDATING`。

接手者先复现最后一项关键验证。handoff 与其描述的实现分开提交，并运行 `make handoff-validate`。不得记录凭证值。
