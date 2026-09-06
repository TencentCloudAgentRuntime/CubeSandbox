# AGENTS Policy

## 开发测试注意事项

- AGC = Agent Cluster. 公有云类 K8S 产品. 尽可能保证 k8s 语义兼容 + 快速端到端启动. 项目目标为兼容标准 Pod 语义的同时实现基于 cube sandbox 的 pod 创建快路径.

- 开发应遵循最小化改动的原则, 如非必要, 就避免引入改动.

- 使用 task --list-all 命令查看项目的各类脚本入口. 

- 测试
    - 本项目采用多worktree并行开发模式. 当前 worktree 的测试集群环境见 [本地 worktree 配置](local.env)
    - 登陆节点可使用 node-shell 插件, 例如 k node-shell 172.17.137.56 -- kubelet --version
    - 如果cube节点受发布组件影响, 无法通过 node-shell 登陆节点, 可以先通过node-shell登陆非cube节点, 然后把 [本地 worktree 配置](local.env) 中的密钥上传到node-shell容器后再通过ssh登陆到目标节点. 
    - 由于 cube 依赖 pvm, 而 pvm 对内核版本有要求, 要使用集群内的OS版本为TS4的节点作为cube运行时节点.
    - 涉及到代码层面的开发变动, 必须到测试集群中进行针对性测试, 通过验收后才能认为完成.

- 开发完成汇报结果时, 要写一个面向 reviewer 的 PR description 文档. 此文档不必与openspec的changes文档重复, 而是要包含主要思路、关键改动点、每个改动点要解决的问题和必要性等要点.

- 在停止工作前, 应该回顾本次开发引入的改动, 识别哪些是调试期间所做的 workaround, 分析并验证此workaround是否是非必要的临时更改. 若是, 应该收敛改动并且到集群做复测. 