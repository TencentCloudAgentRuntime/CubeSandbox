# PVM 内核性能优化提交调研报告

调研对象：`https://cnb.cool/CubeSandbox/OpenCloudOS-Kernel.git`

调研版本：`6.6.69-1.2.cubesandbox`

版本提交：`0de43d6b3bcd21cae7b5aa0fcc392dced19fdbce`

调研日期：2026-09-13

## 1. 结论摘要

`6.6.69-1.2.cubesandbox` 不是简单合入 PVM 支持的内核版本。其提交记录显示，该分支围绕
PVM 的核心开销路径做过成体系优化，重点覆盖：

1. Guest/Host 切换路径：引入 PVM switcher 与 direct switching，降低常见 VM exit 回到
   hypervisor 的频率和状态切换成本。
2. 页表与 TLB 路径：使用 host PCID 减少 guest TLB flush，扩大 KVM per-MMU CR3/PGD cache，
   用 hypercall 优化 CR3/TLB 相关 PVOPS。
3. KVM MMU 页分配：新增页分配池，降低 shadow page table / TDP MMU / PVM MMU 场景中
   `__get_free_page()` 的成本。
4. Guest 特性裁剪：在 PVM guest 中默认关闭 CPU mitigations，禁用或清理不稳定、未高效支持
   或收益不足的 CPU/PMU/TSC/BTF 相关能力。
5. 性能可观测性：补齐 PVM exit reason、`perf kvm`、guest callchain 等支持，便于后续定位
   hypercall、VM exit 和 guest 栈。

这些改动与 `context switch`、`fork`、`pagefault` 三类指标高度相关。尤其是 direct
switching、host PCID、CR3/PGD cache、PVM MMU PVOPS 和 KVM 页分配池，能够直接影响进程切换、
地址空间切换、缺页和系统调用路径。

## 2. 调研方法

本次调研主要依据公开仓库提交记录、commit message 和关键 diff，使用如下口径筛选：

- 版本范围：`6.6.69-1.2.cubesandbox` tag 可达提交。
- 关键词：`pvm`、`direct switch`、`pcid`、`tlb`、`cr3`、`pgd`、`shadow`、`mmu`、
  `kmem_cache`、`__get_free_page`、`mitigation`、`pmu`、`tsc`、`syscall`、`perf`。
- 重点文件：`arch/x86/kvm/pvm/`、`arch/x86/kernel/pvm.c`、`arch/x86/entry/`、
  `arch/x86/kvm/mmu/`、`virt/lib/kmem_cache.c`、`kernel/cpu.c`、`arch/x86/events/`。

注意：本报告只分析提交记录和代码意图，不声称已经完成逐 patch 性能归因。精确归因仍需要在
同一节点、同一 payload、同一 guest/host 组合下做 A/B 测试。

## 3. 提交脉络

公开 tag 中标题包含 `pvm` 的提交约 116 条。按时间与功能看，可分为五个阶段：

| 阶段 | 代表提交 | 主要内容 |
| --- | --- | --- |
| PVM ABI 与基础框架 | `83009b5`, `693507d`, `dc0a9fe`, `7797b64` | 文档、ABI、KVM vendor、host MMU 初始化 |
| Entry / event / hypercall | `4d2e46f`, `8640eb5`, `d820b5e`, `54e9d29`, `19c8c88` | switcher、direct switching、事件投递、syscall 处理 |
| MMU / TLB / CR3 | `d94bbe5`, `64fcf98`, `f4b5741`, `35e0c0f`, `23ecabf` | host PCID、CR3 切换 hypercall、MMU PVOPS、root cache |
| Guest 特性收敛 | `d4ee59f`, `78fe7e1`, `a186202`, `f56c632`, `ac64bc1` | mitigations、PMU、CPUID/TSC/BTF 能力处理 |
| 可观测性与稳定性 | `c9ba362`, `d6d4421`, `d66bc16`, `291b4d4`, `0de43d6` | perf 支持、exit reason、shadow paging UAF 修复 |

## 4. 核心性能优化措施

### 4.1 PVM switcher：缩短 guest/host 世界切换路径

代表提交：

- `4d2e46f x86/entry: Implement switcher for PVM VM enter/exit`
- `8640eb5 x86/entry: Implement direct switching for the switcher`
- `af77616 KVM: x86/PVM: Enable direct switching`

PVM guest 在底层 CPU 上以 CPL3 运行，因此 guest/host 切换与传统硬件虚拟化的 VMX root/non-root
切换不同，更接近 user/kernel 切换。`4d2e46f` 引入 switcher，复用 host entry 处理 PVM VM
enter/exit：当从 CPL3 进入且标记为 PVM guest active 时，入口被识别为 VM exit 并转发给
hypervisor。

`8640eb5` 进一步引入 direct switching。commit message 明确说明，在部分 VM exit 场景中，
switcher 可以不回到 hypervisor，而是直接完成 guest 内部 user/supervisor mode 切换，从而减少
guest/host 状态切换开销。当前主要覆盖 user mode syscall 和 ERETU synthetic instruction。

性能意义：

- `lat_syscall`：系统调用入口可减少回 hypervisor 的频率。
- `lat_ctx`：上下文切换中涉及 syscall、iret/sysret、CR3/GS/TLS 状态切换，direct switching 可降低
  固定成本。
- `fork/exec`：进程创建路径中有密集 syscall、地址空间切换和内核态路径，受该优化影响。

风险控制：

- `67f947c` 增加 `kvm_pvm.direct_switch` 模块参数，可显式关闭 direct switch，适合作为 A/B 开关。
- `0b02309` 在 PVCS/GPC inactive 时禁用 direct switching，避免 switcher 直接访问无效 PVCS。
- `140647f` 在无 PCID 场景下检查 root page 有效性，避免错误使用 direct switching。

### 4.2 Host PCID：降低 guest TLB flush 成本

代表提交：

- `d94bbe5 KVM: x86/PVM: Use host PCID to reduce guest TLB flushing`

该提交是 PVM 页表性能路径的关键优化。commit message 明确指出：host 没有用完所有 PCID，PVM
可以利用 host PCID 减少 guest TLB flushing。

实现要点：

- 新增 per-CPU `pvm_tlb_state`，维护 `pvm + root_hpa` 到 host PCID 的映射。
- 为 guest page table root 分配 host PCID，命中时可在 CR3 中设置 `CR3_NOFLUSH`。
- 实现 PVM 专用的 `flush_tlb_all`、`flush_tlb_current`、`flush_tlb_gva`、`flush_tlb_guest`
  回调。
- `pvm_flush_hwtlb_guest()` 中明确说明，PVM 使用 PGD-tagged TLB，部分 guest flush 场景不需要
  额外硬件 TLB flush。

性能意义：

- `pagefault`：缺页处理后常伴随页表和 TLB 维护，减少 flush 能降低尾部成本。
- `fork`：fork 后新旧地址空间切换频繁，PCID 命中可减少 CR3 切换造成的 TLB flush。
- `context switch`：进程切换需要切换地址空间，PCID 命中直接降低切换成本。

这类优化通常对多进程、小工作集、频繁切换场景收益明显，与你实测中 `fork/context switch`
差异方向一致。

### 4.3 CR3/PGD cache：减少 shadow page table evict/rebuild

代表提交：

- `92b2107 KVM: x86/mmu: Expand max capacity of per-MMU CR3/PGD caches`
- `35e0c0f KVM: x86: introduce configurations for per-MMU CR3/PGD caches`
- `23ecabf KVM: x86: enlarge default per-MMU CR3/PGD cache number`

`35e0c0f` 引入 `prev_roots_num` 模块参数，使 KVM per-MMU previous roots 数量可配置。commit
message 说明该 cache 可减少 shadow page table evict 和 rebuild overhead。

`23ecabf` 将默认 `KVM_MMU_NUM_PREV_ROOTS` 从 3 提高到 7。commit message 明确提到 Cube SCF
环境：一次请求至少涉及 3 个用户进程上下文切换，因此需要 cache 至少 4 个启用 KPTI 后的 guest
用户进程。

性能意义：

- `fork` 和 `exec`：新进程引入新 PGD/root，cache 增大后可减少 root 频繁淘汰与重建。
- `context switch`：多个用户进程来回切换时，previous root 命中率提高。
- `pagefault`：shadow page table 被 evict 后重建会放大缺页成本，cache 增大可减少此类放大。

这是最明确面向 Cube 多进程业务模型的优化之一。

### 4.4 KVM MMU 页分配池：降低 `__get_free_page()` 成本

代表提交：

- `3ae0fba KVM: Introduce kmem_cache to save costly calls to __get_free_page()`
- `4f9e00e KVM/x86: Apply kmem_cache_get_free_page() to x86 hw vendors`
- `a4f4f85 KVM/x86: Apply kmem_cache_get_free_page() to PVM`

`3ae0fba` 新增 `kmem_cache_get_free_page()`。commit message 明确说明，内存子系统管理 free page
的策略较复杂，对于 KVM SPT/TDP MMU 这类局部负载，通过一定程度的 pooling 隐藏开销更合适。

实现要点：

- 每 CPU 为特定 `gfp_flags` 维护 PAGE_SIZE 页池。
- 后台 kworker 周期性 topup。
- 当前 CPU 上的调用者优先从本 CPU 页池获取页面。
- 池不可用时回退到原始 `__get_free_page()`。

`a4f4f85` 将该接口应用到 PVM `host_mmu.c`，把 `host_mmu_root_pgd` 和 5-level paging 下的
`host_mmu_la57_top_p4d` 分配从 `__get_free_page()` 切换为 `kmem_cache_get_free_page()`。

性能意义：

- 降低 PVM/KVM MMU 初始化和页表路径中的页分配抖动。
- 对频繁创建 VM、频繁构建 shadow page table、缺页密集场景更有价值。
- 对 `pagefault` 和冷启动尾延迟可能更敏感。

### 4.5 PVM MMU/IRQ/CPU PVOPS：用共享状态和 hypercall 替代昂贵模拟

代表提交：

- `11c0f84 x86/pvm: Implement cpu related PVOPS`
- `207fb74 x86/pvm: Implement irq related PVOPS`
- `f4b5741 x86/pvm: Implement mmu related PVOPS`
- `d24a2ab KVM: x86/PVM: Handle hypercalls for privilege instruction emulation`
- `0288407 x86/kvm: Patch KVM hypercall as PVM hypercall`

这些提交的共同目标是：把 PVM guest 中不可直接执行或执行成本高的特权操作改为 PVM-aware
PVOPS/hypercall 路径，避免通用 trap-and-emulate。

关键点：

- CPU PVOPS：MSR read/write 位于热路径，默认走 hypercall；`FS_BASE`、`KERNEL_GS_BASE` 等可用
  更轻路径处理；`load_tls()` 变化时通知 hypervisor。
- IRQ PVOPS：`save_fl()`、`irq_enable()`、`irq_disable()` 位于热路径，hypervisor 将 IF 状态共享
  到 PVCS，guest 可直接读写；只有存在 IRQ window request 时才 hypercall。
- MMU PVOPS：CR2 从 PVCS 直接读取；`write_cr3()` 通过 hypercall 通知 hypervisor；TLB 相关 PVOPS
  使用 hypercall。
- 特权指令模拟：RDMSR/WRMSR、TLB flush 等热路径特权指令改用 hypercall，commit message 明确写
  “to reduce the emulation overhead”。

性能意义：

- 降低 syscall、上下文切换、缺页、IRQ 开关、TLS/GS 切换等基础系统路径成本。
- 相比每次触发异常再由通用模拟器处理，PVM hypercall 路径更短、更可控。

### 4.6 Guest mitigations 默认关闭：降低安全缓解开销

代表提交：

- `78fe7e1 x86/pvm: Apply CPU_MITIGATIONS_OFF for pvm-guest in a built-in way`

该提交在 `CONFIG_PVM_GUEST` 下把默认 mitigations 策略设为 `CPU_MITIGATIONS_OFF`。commit message
给出的首要动机就是提升 guest load 性能，并指出 pvm-guest 相比 pvm-host 有明显性能损失。

性能意义：

- 影响 syscall、return、indirect branch、上下文切换等广泛热路径。
- 对 `lat_syscall`、`fork/exec`、`context switch` 的基础成本有潜在收益。

边界说明：

- 该提交基于 Cube 的威胁模型判断：VMM/guest domain 可视为 sandbox 内部受信边界的一部分，
  PVM guest 已使用 KPTI 作为基础隔离。
- 这属于明确的安全/性能取舍，不能脱离产品隔离模型单独复用。

### 4.7 Guest CPU/PMU/TSC/BTF 特性收敛

代表提交：

- `d4ee59f x86/cpu/common: Clearing unstable CPUID bits for pvm-guest in a built-in way`
- `a186202 x86/pmu: Disable pvm-guest hw-pmu features`
- `f56c632 x86/pvm: Drop guest X86_FEATURE_TSC_DEADLINE_TIMER feature and more`
- `ac64bc1 bpf: Add --skip_encoding_btf_vars to pahole flags for pvm`
- `b6dbe53 x86/pvm/kvmclock: Drop VDSO_CLOCKMODE_PVCLOCK feature support`

这组提交更偏“让 guest 不走不稳定或低收益路径”，间接改善启动、日志噪声和故障尾延迟。

具体措施：

- 清理 PVM guest 中不稳定或不适合暴露的 CPUID bits，如 `xtopology`、`ssbd`、`tsc_adjust`、
  `arch_capabilities`、`cpuid_fault`、`umip`，后续又统一清理 `tsc_deadline`、`pcid`、
  `3dnowprefetch`。
- 禁用 PVM guest hw PMU，仅使用 software events，避免 guest 初始化阶段访问未支持的 PMU MSR。
- 跳过 BTF vars 编码，避免 BPF 通过 BTF 暴露 per-CPU variable 地址并触发 PVM guest 崩溃。
- 禁用不满足稳定 TSC 条件下的 pvclock vDSO fast path，避免时间回退。

性能意义：

- 减少 guest 初始化阶段访问未支持虚拟硬件导致的 trap/log。
- 避免错误 fast path 带来的恢复后时间异常。
- 减少特性探测和异常处理路径的不确定性。

这类改动不一定提升单项微基准均值，但会改善可预测性和长尾，并降低某些 workload 的异常成本。

### 4.8 PVM perf 可观测性：支撑后续优化闭环

代表提交：

- `c9ba362 KVM: x86/PVM: Introduce uapi/asm/pvm_trace.h header`
- `f7c6714 KVM: x86/PVM: Add pvm_trace.h header files to tools`
- `a2a337d KVM: x86/PVM: Add PVM hypercalls exit reason handling`
- `d6d4421 perf kvm: Add PVM support for perf kvm`
- `d66bc16 KVM: x86: Add guest callchain info interfaces for perf-core`
- `c4a1f6f perf/core: Use KVM generic callbacks for guest call-chain`
- `8d7f7d4 perf/core: Support sampling x86 guest callchains`
- `f37b4d1 tools/perf: Support PERF_CONTEXT_GUEST_* flags`

这些提交不直接降低运行时开销，但非常关键。PVM 的瓶颈常出现在 guest/hypervisor 边界，如果
perf 不能识别 PVM exit reason、hypercalls 和 guest callchain，就很难定位具体开销来源。

这组改动为后续回答以下问题提供工具基础：

- direct switching 是否命中？
- 哪类 PVM hypercall 最频繁？
- VM exit 主要来自 syscall、TLB flush、MSR 还是 #PF？
- guest kernel/user 栈在 host perf 中能否正确归因？

## 5. 与实测指标的关联分析

### 5.1 Context switch

强相关优化：

- direct switching：`4d2e46f`、`8640eb5`、`af77616`
- host PCID：`d94bbe5`
- IRQ/MSR/TLS PVOPS：`11c0f84`、`207fb74`
- CR3/PGD cache：`23ecabf`
- mitigations off：`78fe7e1`

原因：上下文切换会触发调度、地址空间切换、TLS/GS 状态处理、IRQ 状态处理和可能的 TLB 维护。
PVM 下这些动作可能放大为 guest/hypervisor 边界操作。上述优化均在减少边界切换或避免 TLB
flush/rebuild。

### 5.2 Fork / Exec

强相关优化：

- KVM per-MMU CR3/PGD cache：`35e0c0f`、`23ecabf`
- host PCID：`d94bbe5`
- CR3 切换 hypercall：`64fcf98`
- KVM 页分配池：`3ae0fba`、`a4f4f85`
- mitigations off：`78fe7e1`

原因：fork/exec 是典型的地址空间和页表压力场景。fork 需要复制/建立 mm 结构与页表元数据，
exec 会替换地址空间，二者都会提高 CR3 切换、SPT root 查找、TLB flush 和缺页概率。扩大 root
cache 与 host PCID 对该路径尤其直接。

### 5.3 Pagefault

强相关优化：

- MMU PVOPS：`f4b5741`
- allowed VA/#PF 处理：`c650d18`
- host PCID：`d94bbe5`
- KVM 页分配池：`3ae0fba`、`a4f4f85`
- shadow MMU for PVM：`006a341`

原因：PVM 缺页路径既要处理 guest fault，又要维护 host shadow page table。CR2 直接从 PVCS
读取、TLB flush 减少、SPT 页分配优化，都可能影响 `lat_pagefault`。

## 6. 其他稳定性与尾延迟相关提交

以下提交不一定是 PVM 专属性能优化，但可能影响大规模创建和长尾：

- `0de43d6 KVM: x86: Fix shadow paging use-after-free due to unexpected role`
- `291b4d4 KVM: x86: Fix shadow paging use-after-free due to unexpected GFN`
- `b85200d writeback: Avoid softlockup when switching many inodes`
- `aa4e6a0 writeback: Avoid excessively long inode switching times`
- `5b4ad0d jbd2: prevent softlockup in jbd2_log_do_checkpoint()`
- `0df647b x86/pvclock: Clamp TSC delta to zero when TSC goes backwards after restore`

这些提交更偏可靠性、恢复一致性或软锁死规避。它们未必改善中位数，但可能减少高并发、多 VM、
大量 inode 或恢复场景中的长尾和异常。

## 7. 初步归因判断

结合提交内容和实测现象，仓库构建内核相对公司内 PVM 内核在 `context switch`、`fork`、
`pagefault` 上更快，较可能来自以下差异组合：

1. 公司内核若缺少或关闭 direct switching，会显著放大 syscall/context switch 路径。
2. 公司内核若没有 host PCID 或 PCID cache 策略不同，会增加 CR3 切换和 TLB flush 成本。
3. 公司内核若 `KVM_MMU_NUM_PREV_ROOTS` 仍为 3，或未启用 `prev_roots_num=7` 默认值，多进程
   fork/exec 场景会更容易触发 shadow root evict/rebuild。
4. 公司内核若没有 `kmem_cache_get_free_page()` 系列补丁，SPT/PVM MMU 页分配路径可能更慢或
   抖动更大。
5. 公司内核若保留 guest mitigations、hw PMU、TSC deadline、BTF vars 等特性，可能增加系统调用、
   启动初始化和异常处理成本。

上述判断是基于提交意图和代码路径的技术推断，不等同于严格因果证明。

## 8. 建议的后续 A/B 验证

为了把“提交记录支持”推进到“可量化归因”，建议按如下顺序做同节点 A/B：

1. Direct switching：
   - A：默认 `kvm_pvm.direct_switch=1`
   - B：设置 `kvm_pvm.direct_switch=0`
   - 重点指标：`lat_syscall`、`lat_ctx`、`lat_proc fork/exec`

2. KVM MMU root cache：
   - A：默认 `prev_roots_num=7`
   - B：回退到 `prev_roots_num=3`
   - 重点指标：`fork`、`exec`、多进程 context switch、pagefault

3. Guest mitigations：
   - A：PVM guest 默认 `CPU_MITIGATIONS_OFF`
   - B：强制开启或使用对照内核默认策略
   - 重点指标：`lat_syscall`、`lat_ctx`、`fork/exec`

4. Host PCID：
   - 优先通过 patch 级对照或 CPU/内核参数确认是否命中 `CR3_NOFLUSH` 路径。
   - 重点指标：`lat_ctx`、`lat_pagefault`、多进程 workload。

5. KVM 页分配池：
   - 对比是否包含 `3ae0fba/4f9e00e/a4f4f85`。
   - 重点指标：VM cold start、pagefault、并发创建尾延迟。

验证时必须固定：

- 同一物理或云主机节点。
- 同一 host kernel 与 guest kernel 组合变量，每次只改一类因素。
- 同一 runtime、镜像 digest、CPU/内存规格、NUMA/CPU 频率策略。
- 每项至少 15 个有效样本，并报告 median、P95、bootstrap CI。

## 9. 附：重点提交清单

| 提交 | 分类 | 说明 |
| --- | --- | --- |
| `4d2e46f` | switcher | 实现 PVM VM enter/exit switcher |
| `8640eb5` | direct switching | switcher 直接处理 syscall/ERETU 等常见切换 |
| `af77616` | direct switching | KVM PVM 侧启用 direct switching |
| `67f947c` | direct switching | 增加 `kvm_pvm.direct_switch` 开关 |
| `0b02309` | direct switching | PVCS/GPC inactive 时禁用 direct switch |
| `d94bbe5` | TLB | 使用 host PCID 减少 guest TLB flush |
| `64fcf98` | CR3 | `PVM_HC_LOAD_PGTBL` 一次加载 kernel/user PGD |
| `f4b5741` | MMU PVOPS | CR2/PVM CR3/TLB flush PVOPS |
| `207fb74` | IRQ PVOPS | IF 状态通过 PVCS 共享，减少 VM exit |
| `11c0f84` | CPU PVOPS | MSR/TLS/GS 热路径改为 PVM PVOPS/hypercall |
| `d24a2ab` | hypercall | RDMSR/WRMSR/TLB flush 等特权指令改 hypercall |
| `92b2107` | KVM MMU | previous roots 数组最大容量扩到 11 |
| `35e0c0f` | KVM MMU | 增加 `prev_roots_num` 参数 |
| `23ecabf` | KVM MMU | 默认 previous roots 从 3 扩到 7 |
| `3ae0fba` | 页分配 | 引入 `kmem_cache_get_free_page()` 页池 |
| `a4f4f85` | PVM MMU | PVM host MMU 初始化改用页池 API |
| `78fe7e1` | guest 配置 | PVM guest 默认 `CPU_MITIGATIONS_OFF` |
| `a186202` | guest 配置 | 禁用 PVM guest hw PMU |
| `d4ee59f` | guest 配置 | 清理 PVM guest 不稳定 CPUID bits |
| `f56c632` | guest 配置 | 清理 TSC deadline、PCID 等 guest feature |
| `ac64bc1` | BTF | 跳过 BTF vars 编码，避免 PVM guest 崩溃 |
| `c9ba362` | perf | 增加 PVM exit reason UAPI |
| `d6d4421` | perf | `perf kvm` 支持 PVM |
| `d66bc16` | perf | KVM guest callchain 信息接口 |

