# PVM 内核 Tencent 作者性能优化专项调研报告

调研对象：`https://cnb.cool/CubeSandbox/OpenCloudOS-Kernel.git`

调研版本：`6.6.69-1.2.cubesandbox`

版本提交：`0de43d6b3bcd21cae7b5aa0fcc392dced19fdbce`

调研口径：仅统计 `Author` 邮箱为 `@tencent.com` 的提交；不把仅由 Tencent committer 合入、但
作者不是 Tencent 的提交计入“腾讯作者优化”。

调研日期：2026-09-13

## 1. 结论摘要

按严格 Author 口径，`6.6.69-1.2.cubesandbox` 可达历史中共有 50 个 `@tencent.com` 作者提交。
其中与 PVM 性能、尾延迟或性能分析直接相关的提交主要集中在五类：

1. KVM MMU root cache 扩容：明确面向 Cube SCF 多进程请求模型，减少 shadow page table
   evict/rebuild。
2. KVM/PVM MMU 页分配池：用 per-CPU PAGE_SIZE cache 降低 `__get_free_page()` 成本。
3. PVM guest 特性和安全缓解收敛：关闭 guest mitigations，禁用 hw PMU，清理 TSC deadline、
   guest PCID 等不稳定或未高效支持的特性。
4. PVM 可观测性增强：为 `perf kvm`、PVM exit reason、guest callchain 提供支持。
5. PVM 运行和构建配置：将 `KVM_PVM` 纳入 release config，关闭 `CONFIG_RANDOMIZE_MEMORY`，
   避免 PVM 固定地址空间与 KASLR 冲突。

需要特别说明：PVM switcher、direct switching、host PCID 等最核心的基础 patch，主要 Author 是
`antgroup.com`。它们在该内核中存在，并且很可能影响 `context switch/fork/pagefault`，但不应在
严格 Author 口径下归为 Tencent 作者提交。Tencent 作者提交中，对这三类指标最直接的优化是
CR3/PGD cache 扩容、KVM 页分配池、guest mitigations off 和 guest feature 收敛。

## 2. Tencent 作者提交概览

| 作者 | 邮箱 | 数量 | 与 PVM 性能相关性 |
| --- | --- | ---: | --- |
| Like Xu | `likexu@tencent.com` | 31 | PVM guest 特性收敛、页分配池、perf、配置、时间稳定性 |
| Yong He | `alexyonghe@tencent.com` | 7 | KVM MMU root cache、PVM unsupported syscall 日志、memcg 修复 |
| Jinrong Liang | `cloudliang@tencent.com` | 5 | PVM perf/trace/exit reason |
| Jianping Liu | `frankjpliu@tencent.com` | 5 | 发行构建、驱动复制，和 PVM 性能关系弱 |
| Huang Cun | `cunhuang@tencent.com` | 1 | 发行构建，和 PVM 性能关系弱 |
| Ze Gao | `zegao@tencent.com` | 1 | BPF 测试修复，和 PVM 性能关系弱 |

后续章节只展开与 PVM 性能、尾延迟、可观测性相关的提交。

## 3. 强相关优化

### 3.1 KVM MMU root cache 扩容

代表提交：

- `92b2107 KVM: x86/mmu: Expand max capacity of per-MMU CR3/PGD caches`
- `35e0c0f KVM: x86: introduce configurations for per-MMU CR3/PGD caches`
- `23ecabf KVM: x86: enlarge default per-MMU CR3/PGD cache number`

作者：Yong He `<alexyonghe@tencent.com>`

优化内容：

- 将 `struct kvm_mmu.prev_roots[]` 最大容量从固定 3 扩展到 11。
- 新增 `prev_roots_num` 模块参数，允许配置 per-MMU CR3/root_hpa cache pair 数量。
- 将默认 `KVM_MMU_NUM_PREV_ROOTS` 从 3 提高到 7。

提交意图非常明确。`35e0c0f` 的 commit message 写明，更多 per-MMU CR3/root_hpa cache pair
有助于减少 shadow page table evict 和 rebuild overhead。`23ecabf` 进一步点名 Cube SCF
环境：一次请求至少涉及 3 个用户进程上下文切换，因此需要 cache 至少 4 个启用 KPTI 后的 guest
用户进程。

性能影响判断：

- 对 `fork/exec` 强相关：进程创建和 exec 会改变地址空间，增加 CR3/PGD root 切换压力。
- 对 `context switch` 强相关：多用户进程切换时，previous roots 命中率越高，越少触发 shadow
  root 淘汰和重建。
- 对 `pagefault` 中高相关：shadow root 被淘汰后，后续缺页可能放大为更多页表重建工作。

这是 Tencent 作者提交中最明确、也最贴近你实测指标的一组性能优化。

### 3.2 KVM/PVM MMU 页分配池

代表提交：

- `3ae0fba KVM: Introduce kmem_cache to save costly calls to __get_free_page()`
- `4f9e00e KVM/x86: Apply kmem_cache_get_free_page() to x86 hw vendors`
- `a4f4f85 KVM/x86: Apply kmem_cache_get_free_page() to PVM`

作者：Like Xu `<likexu@tencent.com>`

优化内容：

- 新增 `kmem_cache_get_free_page()` / `kmem_cache_put_page()`。
- 为特定 `gfp_flags` 维护 per-CPU PAGE_SIZE cache。
- 通过后台 kworker 周期性补充页池。
- 调用方优先从当前 CPU 页池获取 free page，页池不可用时回退到 `__get_free_page()`。
- PVM `host_mmu.c` 中的 `host_mmu_root_pgd`、`host_mmu_la57_top_p4d` 分配改用该接口。

提交意图同样明确。`3ae0fba` 的 commit message 直接写明目标是节省昂贵的
`__get_free_page()` 调用，并提到 KVM SPT/TDP MMU 这类局部负载可通过 pooling 隐藏内存子系统
复杂分配开销。

性能影响判断：

- 对 PVM VM 创建、host MMU 初始化和 shadow page table 建立有直接帮助。
- 对缺页密集、并发 VM 创建、shadow page table 频繁扩展场景可能降低均值和尾延迟。
- 对 `pagefault` 的影响通常取决于缺页是否触发新 shadow page 分配；不是每次 pagefault 都收益。

### 3.3 PVM guest 默认关闭 CPU mitigations

代表提交：

- `78fe7e1 x86/pvm: Apply CPU_MITIGATIONS_OFF for pvm-guest in a built-in way`

作者：Like Xu `<likexu@tencent.com>`

优化内容：

- 在 `CONFIG_PVM_GUEST` 下，默认将 `cpu_mitigations` 初始化为 `CPU_MITIGATIONS_OFF`。
- 不依赖 cmdline，在 guest 内建该策略。

commit message 明确给出首要动机：获取更好的 guest load 性能，并指出 pvm-guest 相比 pvm-host
有明显性能损失。同时，该提交说明 Cube 的安全模型可以接受 VMM/guest domain 作为 sandbox 的一部分，
guest 侧已有 KPTI 作为基础隔离。

性能影响判断：

- 对 `lat_syscall`、`context switch`、`fork/exec` 均有潜在影响。
- CPU mitigations 会影响间接分支、返回、用户态/内核态切换等热路径；关闭后通常能降低系统调用和
  进程切换固定成本。
- 这是明确的安全/性能取舍，不能脱离 Cube/PVM 隔离模型泛化使用。

### 3.4 PVM guest CPU feature 收敛

代表提交：

- `d4ee59f x86/cpu/common: Clearing unstable CPUID bits for pvm-guest in a built-in way`
- `f56c632 x86/pvm: Drop guest X86_FEATURE_TSC_DEADLINE_TIMER feature and more`
- `3565d61 x86/cpu/common: Allow more bits in clearcpuid= parameter`

作者：Like Xu `<likexu@tencent.com>`

优化内容：

- 在 PVM guest 中内建清理不稳定或未支持的 CPUID bits。
- 清理项包括 `XTOPOLOGY`、`SSBD`、`TSC_ADJUST`、`ARCH_CAPABILITIES`、`CPUID_FAULT`、
  `UMIP`，后续进一步统一清理 `TSC_DEADLINE_TIMER`、`PCID`、`3DNOWPREFETCH`。
- 扩大 `clearcpuid=` 参数容量，避免较多 CPU feature 需要清理时被截断。

`f56c632` 说明 PVM guest 可使用默认 APIC timer，并记录清理 TSC deadline 后未观察到性能下降。
更重要的是，该提交把 Intel/AMD guest 特性处理统一，减少平台差异。

性能影响判断：

- 主要收益是避免 guest 选择 PVM host 不能正确或高效模拟的 feature path。
- 对启动、恢复、时间、timer、异常处理路径有稳定性收益。
- 该类提交不是单纯“加速 patch”，但会避免错误 fast path 或未支持特性造成 trap、日志噪声和长尾。

### 3.5 禁用 PVM guest hw PMU

代表提交：

- `a186202 x86/pmu: Disable pvm-guest hw-pmu features`

作者：Like Xu `<likexu@tencent.com>`

优化内容：

- PVM guest 下 `check_hw_exists()` 直接返回 false。
- guest 只使用 software events，不暴露 hw PMU。

提交说明指出，当前 PVM-host 缺少 vPMU emulation，AMD pvm-guest 会假定有基础 counters 并在系统
初始化阶段访问相关 MSR，产生大量 host 日志噪声。

性能影响判断：

- 主要减少启动初始化阶段的无效 MSR 访问和日志噪声。
- 对普通运行期 CPU 微基准收益有限。
- 对 cold boot、异常路径、日志系统压力和可观测性稳定性更有价值。

## 4. 中相关优化与稳定性措施

### 4.1 PVM/PVH entry 禁用 profiling

代表提交：

- `2334843 x86/pvm: Don't profile PVH entry code`
- `8c07ba4 x86/pvm: don't profile PVH entry code only in the PIE mode`

作者：Like Xu `<likexu@tencent.com>`

优化内容：

- 在 `CONFIG_FUNCTION_TRACER` 启用时，避免 PVH entry 早期重定位前插入 `__fentry__`。
- 后续收敛为仅 PIE mode 下禁用 profiling。

该提交的直接目标是避免启动失败，而不是运行期性能优化。但它也说明 PVM early boot 对
profiling/ftrace 插桩很敏感。对于冷启动路径，应谨慎开启 tracing/profile 类能力。

### 4.2 PVM release 配置和地址随机化处理

代表提交：

- `1f6a59f config: Add PVM support to dist/configs/50variant/release/default.config`
- `fee87f4 config: Disable CONFIG_RANDOMIZE_MEMORY to support PVM`

作者：Like Xu `<likexu@tencent.com>`

优化内容：

- 在 release default config 中加入 `CONFIG_KVM_PVM=m`，使 CVM 无嵌套虚拟化时也可通过
  `kvm-pvm.ko` 初始化 `/dev/kvm`。
- 关闭 `CONFIG_RANDOMIZE_MEMORY`。原因是 PVM host/guest 使用固定地址 memory-mapped space
  传递 switch states，不支持内存地址随机化。

性能影响判断：

- 这类提交是 PVM 可用性和兼容性基础，不是直接微基准优化。
- 固定地址空间是 PVM switcher/PVCS 机制的前提，间接支撑低成本切换路径。

### 4.3 TSC、pvclock 与迁移后时间稳定性

代表提交：

- `b6dbe53 x86/pvm/kvmclock: Drop VDSO_CLOCKMODE_PVCLOCK feature support`
- `0df647b x86/pvclock: Clamp TSC delta to zero when TSC goes backwards after restore`
- `38ea758 timekeeping: Dumpstack if do_settimeofday64() rejects backward monotonic clock`
- `d26c19d KVM: x86/pvm: Fix guest X86_CR4_TSD emulation`
- `a1f4c4c x86/pvm: Support guest PR_TSC_SIGSEGV start from PVM-host 005`

作者：Like Xu `<likexu@tencent.com>`

优化内容：

- 在 PVM guest 中不再强制使用 pvclock vDSO fast path，避免不稳定 TSC 下用户态观察到时间回退。
- guest 恢复后若 TSC 回退，`pvclock` delta clamp 为 0，避免无符号下溢导致时间跳到数百年后。
- 修复 `PR_TSC_SIGSEGV` / `X86_CR4_TSD` 相关模拟和恢复行为。
- timekeeping 增加诊断日志，便于定位虚拟化环境下时间基准扰动。

性能影响判断：

- `b6dbe53` 可能牺牲部分 gettimeofday/clock_gettime fast path 性能，换取时间正确性。
- `0df647b`、`d26c19d` 更偏恢复稳定性，避免迁移/恢复后时间异常引发级联故障。
- 对 fork/context switch/pagefault 不是主因，但对长时间运行、迁移恢复和测试可信度很重要。

### 4.4 Unsupported feature/syscall 日志与 BTF vars 收敛

代表提交：

- `949fd5c x86/pvm: logs for unsupported syscalls`
- `2a69584 x86/pvm: logs for unsupported PR_TSC_SIGSEGV feature`
- `2693d14 x86/pvm: Change the log format when an unsupported feature is used`
- `ac64bc1 bpf: Add --skip_encoding_btf_vars to pahole flags for pvm`

作者：Yong He、Like Xu

优化内容：

- 对 `modify_ldt`、`PR_TSC_SIGSEGV` 等 PVM unsupported feature 增加可识别日志。
- 统一日志格式，便于告警系统按单一规则识别 `unsupported PVM feature`。
- 跳过 BTF vars 编码，避免 BPF 通过 BTF 暴露 per-CPU variable 地址并导致 PVM guest 崩溃。

性能影响判断：

- 日志提交本身不提升性能，但能帮助识别 workload 是否踩到 PVM 慢路径或不支持路径。
- BTF vars 收敛主要是稳定性和安全性，间接降低异常路径成本。

## 5. PVM 性能可观测性增强

代表提交：

- `c9ba362 KVM: x86/PVM: Introduce uapi/asm/pvm_trace.h header`
- `f7c6714 KVM: x86/PVM: Add pvm_trace.h header files to tools`
- `a2a337d KVM: x86/PVM: Add PVM hypercalls exit reason handling`
- `0c685a9 KVM: x86/PVM: Provide exit reason for PVM VM entry fails`
- `d6d4421 perf kvm: Add PVM support for perf kvm`
- `d66bc16 KVM: x86: Add guest callchain info interfaces for perf-core`
- `c4a1f6f perf/core: Use KVM generic callbacks for guest call-chain`
- `8d7f7d4 perf/core: Support sampling x86 guest callchains`
- `f37b4d1 tools/perf: Support PERF_CONTEXT_GUEST_* flags`

作者：Jinrong Liang、Like Xu

优化内容：

- 为 PVM 增加 exit reason UAPI，并同步到 tools。
- `perf kvm` 支持 PVM。
- perf core/KVM 增加 guest callchain 采样能力。
- 支持 `PERF_CONTEXT_GUEST_KERNEL`、`PERF_CONTEXT_GUEST_USER`。

性能影响判断：

- 这组不是直接加速路径，但对 PVM 性能优化闭环非常关键。
- 它能帮助确认开销来自 syscall、TLB flush、MSR、LOAD_PGTBL、IRQ_HALT、page fault 还是 VM entry。
- 对后续做逐 patch A/B 和 flamegraph 归因很有价值。

## 6. 与上游或非 Tencent 作者提交的边界

上一版全量报告中提到的以下关键 PVM patch，在该仓库中确实存在，但严格 Author 口径下不属于
Tencent 作者提交：

| 提交 | 作者邮箱 | 内容 |
| --- | --- | --- |
| `4d2e46f` | `antgroup.com` | PVM VM enter/exit switcher |
| `8640eb5` | `antgroup.com` | switcher direct switching 主体 |
| `af77616` | `antgroup.com` | KVM PVM 侧启用 direct switching |
| `d94bbe5` | `antgroup.com` | 使用 host PCID 减少 guest TLB flush |
| `64fcf98` | `antgroup.com` | PVM CR3 切换 hypercall |
| `f4b5741` | `antgroup.com` | PVM MMU PVOPS |
| `207fb74` | `antgroup.com` | PVM IRQ PVOPS |
| `11c0f84` | `antgroup.com` | PVM CPU/MSR/TLS PVOPS |
| `d24a2ab` | `antgroup.com` | privileged instruction hypercall 处理 |

这些 patch 对 PVM 性能非常关键，但若问题是“腾讯作者做了哪些优化”，应将它们列为基线能力或
非 Tencent 作者贡献，而不是 Tencent-authored 优化。

## 7. 对实测差异的 Tencent 作者归因判断

针对你实测中仓库构建内核在 `context switch`、`fork`、`pagefault` 上更快的现象，按 Tencent
作者提交看，最值得优先怀疑的差异来源如下：

| 优先级 | 可能来源 | 影响指标 | 原因 |
| --- | --- | --- | --- |
| P0 | `23ecabf/35e0c0f/92b2107` root cache 扩容 | `fork`, `exec`, `context switch`, `pagefault` | 减少 CR3/PGD root cache miss、shadow root evict/rebuild |
| P0 | `78fe7e1` guest mitigations off | `lat_syscall`, `context switch`, `fork/exec` | 降低安全缓解带来的入口/返回/分支开销 |
| P1 | `3ae0fba/4f9e00e/a4f4f85` KVM 页分配池 | `pagefault`, VM 创建, 并发尾延迟 | 减少 KVM MMU/SPT/PVM host_mmu 页分配成本 |
| P1 | `d4ee59f/f56c632/a186202` guest feature 收敛 | cold boot, 异常尾延迟, 部分 syscall | 避免 guest 走未高效支持的 PMU/TSC/CPUID 路径 |
| P2 | PVM perf/trace 支持 | 归因能力 | 不直接加速，但决定能否证明差异来自哪个 exit/hypercall |

如果公司内 PVM 内核缺少上述 Tencent-authored patch，或配置不同，那么即使同样包含 PVM 基础能力，
在多进程、频繁地址空间切换和缺页场景下也可能明显慢于仓库构建内核。

## 8. 建议验证顺序

建议优先做以下 A/B：

1. `prev_roots_num=3` vs `7`：
   - 目标：验证 CR3/PGD root cache 对 `fork/context switch/pagefault` 的贡献。
   - 预期：多进程和 fork/exec 负载更敏感。

2. guest mitigations on/off：
   - 目标：验证 `78fe7e1` 对 syscall、context switch 和 fork/exec 的贡献。
   - 预期：`lat_syscall` 与 `lat_ctx` 更敏感。

3. 是否包含 `kmem_cache_get_free_page()` 系列：
   - 目标：验证 KVM MMU 页分配池对 pagefault、VM 创建和并发尾延迟的贡献。
   - 预期：缺页密集和并发创建更敏感。

4. guest feature 清理差异：
   - 目标：对比 PMU、TSC deadline、guest PCID、BTF vars 等是否触发额外 trap/log。
   - 预期：主要影响启动、恢复和异常长尾。

同时建议使用 PVM perf 支持采样，重点观察：

- PVM hypercall exit reason 分布。
- `PVM_HC_LOAD_PGTBL`、`PVM_HC_TLB_FLUSH*`、`PVM_HC_RDMSR/WRMSR` 次数。
- shadow page table rebuild 或 MMU lock 热点。
- guest callchain 是否集中在 fork/exec/page fault 路径。

## 9. 精简清单

| 提交 | 作者 | 类型 | 重要性 |
| --- | --- | --- | --- |
| `92b2107` | Yong He | 扩大 KVM MMU root cache 最大容量 | P0 |
| `35e0c0f` | Yong He | 增加 `prev_roots_num` 参数 | P0 |
| `23ecabf` | Yong He | 默认 previous roots 从 3 扩到 7 | P0 |
| `78fe7e1` | Like Xu | PVM guest 默认关闭 CPU mitigations | P0 |
| `3ae0fba` | Like Xu | 引入 KVM PAGE_SIZE 页分配池 | P1 |
| `4f9e00e` | Like Xu | x86 KVM vendor 使用页分配池 | P1 |
| `a4f4f85` | Like Xu | PVM host MMU 使用页分配池 | P1 |
| `d4ee59f` | Like Xu | 清理 PVM guest 不稳定 CPUID bits | P1 |
| `f56c632` | Like Xu | 清理 TSC deadline、guest PCID 等 feature | P1 |
| `a186202` | Like Xu | 禁用 PVM guest hw PMU | P1 |
| `b6dbe53` | Like Xu | 禁用不稳定 TSC 下 pvclock vDSO fast path | P2 |
| `0df647b` | Like Xu | 恢复后 TSC 回退保护 | P2 |
| `2334843` | Like Xu | PVM/PVH entry 禁用 profiling | P2 |
| `8c07ba4` | Like Xu | 仅 PIE mode 下禁用 PVH profiling | P2 |
| `c9ba362` | Jinrong Liang | PVM exit reason UAPI | 观测 |
| `a2a337d` | Jinrong Liang | PVM hypercall exit reason | 观测 |
| `d6d4421` | Jinrong Liang | `perf kvm` 支持 PVM | 观测 |
| `d66bc16` | Like Xu | KVM guest callchain 信息接口 | 观测 |
| `8d7f7d4` | Like Xu | perf guest callchain 采样 | 观测 |
| `f37b4d1` | Like Xu | perf 支持 guest context flags | 观测 |

