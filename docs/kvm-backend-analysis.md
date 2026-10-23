# VirtualBox KVM 后端补丁深度解析

本文分析 cyberus-technology/virtualbox-kvm 项目（下称"本项目"）的核心补丁
`patches/0001-NEM-Implement-KVM-backend.patch`（4933 行，36 个文件，+3084/−175）。
内容包括：项目思路、补丁如何工作、每个文件改变了什么、以及如果要重新实现，
关键点在哪里。文末附带"无内核驱动模式下的网络机制"专题分析。

> 验证环境：VirtualBox 7.2.20 源码（`/tmp/vbox-apply/src`），补丁通过
> `git am` 干净应用，`VBoxVMM.so` 完整编译链接成功（详见 §2）。

---

## 1. 项目思路

### 1.1 要解决什么问题

VirtualBox 在 Linux 上默认使用自己的 hypervisor：用户态 VMM 通过自研内核模块
`vboxdrv`（SUPDrv）拿到 VT-x/AMD-V 能力，由 HM（Hypervisor Mode）子系统自己做
VMCS 管理、中断芯片模拟（PIC/IO-APIC/LAPIC）、影子页表/嵌套页表等。问题在于：

- `vboxdrv` 是 out-of-tree 内核模块，每次内核升级都可能编译失败或不可用；
- VirtualBox 无法与 QEMU/KVM 同时用 VT-x（同一份硬件资源被独占思路管理）；
- VirtualBox 自研的硬件虚拟化路径（HM）长期只由 Oracle 内部维护，社区难以扩展。

本项目的思路：**不重写 VirtualBox，而是替换它的"底层 hypervisor 提供者"**——
让 Linux 内核的 KVM 负责 CPU 执行、中断芯片和 MSR 处理，VirtualBox 保留
设备模型（DevPCNet、DevE1000、DevAHCI……）、GUI、存储栈和管理 API（VBoxManage）。
用户得到"长得完全一样、但底下跑的是 KVM"的 VirtualBox。

### 1.2 为什么插入点是 NEM

VirtualBox 的 VMM 在设计时就考虑过"宿主系统自带 hypervisor"的情况（Windows 的
Hyper-V、macOS 的 Hypervisor.framework），为此提供了 **NEM（Native Execution
Manager）** 抽象层：

- `VM_IS_NEM_ENABLED(pVM)` 为真时，EM（执行管理器）把 vCPU 执行权整体交给 NEM，
  而不是交给自研的 HM 重编译/VT-x 路径；
- NEM 后端通过 `nemR3Native*` 系列函数与具体 hypervisor 交互，状态存放在
  `pVM->nem.s` / `pVCpu->nem.s`。

上游 VirtualBox 在 Linux 上**只有 NEM 的骨架没有实现**（`NEMR3Native-linux-x86.cpp`
里大部分函数是 stub，直接返回 `VERR_NOT_IMPLEMENTED`）。本补丁做的就是把这个
骨架填成完整的 KVM 后端。这是整个项目最关键的设计决策：

> 复用 NEM 抽象层意味着 EM/PGM/CPUM/TM 等子系统几乎不用感知底层换成了 KVM，
> 补丁的侵入面被限制在"NEM 后端 + 少量跨层契约点"以内。

代价是 NEM 的抽象是为 WHv/HVF 这类"用户态 hypervisor API"设计的，与 KVM 的
ioctl 模型并不完全吻合，补丁中有相当一部分代码是在弥合两者语义差异
（详见 §5、§7）。

### 1.3 补丁的整体布局

按改动量排序（+行数）：

| 文件 | +/− | 作用 |
|---|---|---|
| `src/VBox/VMM/VMMR3/target-x86/NEMR3Native-linux-x86.cpp` | +1212/−156 | **核心**：Linux x86 NEM 后端的 KVM 实现 |
| `src/VBox/VMM/VMMR3/GIMHvOnKvm.cpp`（新文件） | +641 | Hyper-V 半虚拟化接口（GIM）在 KVM 上的实现 |
| `src/VBox/Devices/PC/DevIoApic.cpp` | +183/−4 | IO-APIC 与 KVM 内核 irqchip 的双向状态同步 |
| `include/VBox/vmm/nem.h` | +152/−1 | NEM 层对外新 API（CPUID 查询、Hyper-V leaf 查询等） |
| `src/VBox/VMM/VMMAll/GIMAllHvOnKvm.cpp`（新文件） | +136 | Hyper-V MSR 读写的全上下文实现 |
| `include/VBox/vmm/pdmdev.h` | +121 | PDM 设备辅助回调新增 KVM 相关接口（`pfnKvmSetIrqLine` 等） |
| `src/VBox/VMM/VMMR3/NEMR3NativeTemplate-linux.cpp.h` | +116 | 与 ARMv8 KVM 后端共享的 Linux 通用模板 |
| `src/VBox/VMM/VMMR3/PDMR3DevMiscHlp.cpp` | +102 | 上述 PDM 回调的 R3 实现（转发到 KVM ioctl） |
| `src/VBox/VMM/VMMR3/GIMR3Hv.cpp` | +75/−2 | Hyper-V 功能位按 KVM 实际能力裁剪 |
| `src/VBox/Devices/PC/DevACPI.cpp` | +71 | MADT/其他 ACPI 表适配 |
| `src/VBox/Devices/PC/DevPIC.cpp` | +65 | PIC 在 full-irqchip 模式下透传给内核 |
| 其余 25 个文件 | 各 ≤35 | 构建系统、TSC、CPUID、A20、信号等 |

---

## 2. 应用实测记录

按 README 的流程在 VirtualBox 7.2.20 源码上验证：

```shell
$ tar xf VirtualBox-7.2.20.tar.bz2 && cd VirtualBox-7.2.20
$ git init && git add * && git commit -m "VirtualBox vanilla code"
$ git am <本项目>/patches/0001-NEM-Implement-KVM-backend.patch
应用：NEM: Implement KVM backend        # 干净应用，无 reject、无 fuzz 提示
$ ./configure --with-kvm --disable-kmods --disable-docs --disable-hardening \
              --disable-java --disable-qt --disable-sdl --disable-xpcom --disable-python
Enjoy!                                   # 配置通过，configure 出现 --with-kvm 选项
$ source ./env.sh && kmk VBoxVMM
$ ls out/linux.amd64/release/bin/VBoxVMM.so     # 30MB，链接成功
$ nm VBoxVMM.so | grep NEMR3KvmGetCpuIdLeaves   # 补丁新符号确认落位
```

结论：**当前补丁（版本日期 20260930）精确匹配 VirtualBox 7.2.20**，
README 中"7.1.6"的手动编译说明已过时。构建时只有两个非补丁本身的坑：

- 源码不是 svn/git 检出时 `VBOX_SVN_REV` 为空导致 `buildconfig.cpp` 编译失败，
  需 `kmk VBOX_SVN_REV=<数字>`（任意数字，如 tarball 的 `Config.kmk` 中
  `$Rev: 175113 $`）；
- 打补丁后 `NEMR3Native-linux-x86.cpp` 引入了 `<algorithm>/<string_view>/<vector>`，
  需要 C++17 编译器（VBox 7.2 默认工具链已满足）。

---

## 3. 构建系统的改动

| 位置 | 改动 |
|---|---|
| `configure` | 新增 `--with-kvm` 选项（关闭则回退上游行为）；置位 `VBOX_WITH_KVM`，并按附加选项定义 `VBOX_WITH_KVM_IRQCHIP_FULL`（内核全 irqchip）、`VBOX_WITH_KVM_NESTING`（嵌套虚拟化） |
| `Config.kmk` | 定义上述宏；调整链接与包含路径 |
| `src/VBox/VMM/Makefile.kmk` | 把 `GIMHvOnKvm.cpp`、`GIMAllHvOnKvm.cpp` 编进 VBoxVMM/VBoxVMMAll |
| `src/VBox/Main/Makefile.kmk` 等 | Main/Runtime/Support 对 KVM 宏的条件编译 |
| `src/VBox/HostDrivers/Support/linux/SUPLib-linux.cpp` | `MAP_POPULATE` 预分配（ramprealloc）等无驱动运行所需的内存行为微调 |

设计上值得注意：**`--with-kvm` 是一个整体开关**，关掉后所有改动被
`#ifdef VBOX_WITH_KVM` 屏蔽，回归上游行为——这是补丁可维护性
（每个 VirtualBox 新版本只需 rebase 一次）的关键。

---

## 4. 运行架构：一次 vCPU 执行的完整路径

```
VBox GUI / VBoxManage
    └─ Main (COM API, src/VBox/Main)
        └─ Console → 构造 CFGM 配置树（检测到无 vboxdrv → 选 NEM 路径）
            └─ VMMR3: EM（执行管理器）
                └─ NEMR3Native-linux-x86.cpp  ← 补丁核心
                    ├─ KVM_CREATE_VM / KVM_CREATE_VCPU（打开 /dev/kvm）
                    ├─ 每个 exit：把 CPUMCTX（guest CPU 状态）⇄ kvm_run/kvm_regs 同步
                    ├─ KVM_RUN ioctl —— 真正进入 guest
                    └─ KVM_EXIT_* 分派：MMIO/PIO/IRQ/HALT/msr/hyperv……
                        └─ 回到 VBox 设备模型（PGM/PDM/TRPMAPIC……）处理
```

VirtualBox 依旧负责：内存管理（PGM，EPT/NPT 交给 KVM 的 `KVM_SET_USER_MEMORY_REGION`）、
设备模拟（PIC/IO-APIC/LAPIC 视模式而定）、中断路由决策、时钟（TM）、
保存/恢复（SSM）。KVM 负责：vCPU 执行、特权指令拦截、（可选）中断芯片。

---

## 5. 核心机制详解

### 5.1 VM/vCPU 初始化（`nemR3LnxInitSetupVm`）

1. `open("/dev/kvm")` → `KVM_GET_API_VERSION` 校验 → `KVM_CREATE_VM`；
2. 使能 `KVM_CAP_X86_USER_SPACE_MSR`（用户态处理 guest MSR， Hyper-V MSR 的前提）；
3. **中断芯片二选一**（这是补丁中最重要的架构选择）：
   - **split irqchip**（默认）：
     ```c
     KVM_ENABLE_CAP(KVM_CAP_SPLIT_IRQCHIP, { KVM_IRQCHIP_NUM_IOAPIC_INTR_PINS /*24*/ })
     ```
     内核只模拟 24 脚的 **PIC**；**APIC 仍由 VirtualBox 用户态设备模型模拟**。
   - **full irqchip**（`VBOX_WITH_KVM_IRQCHIP_FULL`）：
     ```c
     KVM_CREATE_IRQCHIP
     ```
     PIC + 双 IO-APIC 全在内核；VBox 设备模型只保留"影子状态"用于 save/restore
     和 `KVM_EXIT_IOAPIC_EOI` 通知。
4. 每 vCPU：`KVM_CREATE_VCPU` + `mmap` 出 `struct kvm_run`；置
   `kvm_valid_regs = KVM_SYNC_X86_REGS | KVM_SYNC_X86_SREGS | KVM_SYNC_X86_EVENTS`，
   让 GPR/段寄存器/事件通过共享内存 `kvm_sync_regs` 同步，减少 `KVM_GET/SET_REGS`
   ioctl 往返；
5. full-irqchip 模式调 `kvmSetGsiRoutingFullIrqChip` 建立 GSI→IRQ 路由表；
6. 嵌套虚拟化开启时，额外 `KVM_GET_STATS_FD` 并解析二进制统计描述符，
   找到 `guest_mode` 计数的偏移（§5.6）。

### 5.2 vCPU 状态同步契约

NEM 层与 KVM 之间有一份"隐式契约"，补丁在多处修复了它的边界情况：

- **进入 KVM_RUN 前**：若 VBox 侧状态脏（fExtrn 标记未置），用
  `KVM_SET_REGS/SREGS/MSRS/CPUID` 把 `CPUMCTX` 推进内核；中断/NMI 写入
  `kvm_run->kvm_sync_regs.regs.events`（`KVM_SYNC_X86_EVENTS`），
  **而不是**旧式 `KVM_INTERRUPT` ioctl（补丁注释说明 KVM 每次 RUN 只注入一个事件，
  VBox 的 inhibit 语义要求更精细的控制）。
- **exit 后**：把寄存器拉回 `CPUMCTX` 并置 `CPUMCTX_EXTRN_*` 标记，
  表示"这些字段的所有权当前在内核"。下次 VBox 设备模型改动了对应状态，
  清标记触发重新同步。
- **中断窗口**：`nemHCLnxHandleInterruptFF` 检查
  `pRun->ready_for_interrupt_injection`（替代旧代码里易出错的
  `events.interrupt.shadow` 判断），只有访客 IF=1 且内核无 shadow 时才
  `PDMGetInterrupt()` 取下一个向量并 `TRPMAssertTrap` 排队。

### 5.3 CPUID 能力协商

VirtualBox 自己检测宿主 CPU 特性并构造给访客的 CPUID，但**检测走的是 VBox 的
代码路径，不知道 KVM 是否支持**。补丁新增：

- `NEMR3KvmGetCpuIdLeaves()`（`nem.h` 导出）：反复以猜测的叶子数调
  `KVM_GET_SUPPORTED_CPUID` 直到尺寸命中（内核没有"查询数量"的 API）；
- `maybeMaskUnsupportedKVMCpuidLeafValues()`：对 0x1/0x6/0x7/0x12/0x14/0x19/0x24/
  0x80000001 等关键叶子，把 VBox 想暴露的特性与 KVM 支持值**按位与**，
  并在 0x1 叶手工补上 hypervisor 位（`X86_CPUID_FEATURE_ECX_HVP`，
  KVM 返回值里不带，因为 KVM 默认不冒充 hypervisor）。

leaf 0x1 的 ebx 被特意排除在掩码外——它装的是 APIC ID，不能拿 KVM 的值覆盖。

### 5.4 中断芯片：split 与 full 两种模式的行为差异

**split 模式**（默认）下 APIC 在 VBox 用户态：

- guest 写 LAPIC TPR 触发 MMIO exit，补丁在 MMIO 写处理里特判
  `XAPIC_TPR_ADDR (0xfee00080)`，把值右移 4 位同步到 `pRun->cr8`
  （`LAPIC_TPR_SHIFT`），让 KVM 侧优先级判断正确；
- guest 处于 init/sipi 等待等状态时，`EMR3.cpp` 的改动保证**留在 NEM 状态**，
  由 KVM 的 PIC 状态机（而非 VBox EM 的 FSM）管理等待 SIPI；
- full 模式下 `NEMR3CanExecuteGuest()` 直接返回 true——PIC 在内核里，
  VBox 没有别的注入路径，非 KVM 执行会弄丢中断（代价：DOS/实模式 A20 游戏失效）。

**full 模式**下设备模型与内核双向同步：

- `PDMR3DevMiscHlp.cpp` 新增一组 PDM 辅助回调
  （`pdmdev.h` 中声明）：`pfnKvmSetIrqLine`、`pfnKvmGetPicState/SetPicState`、
  `pfnKvmGetIoApicState/SetIoApicState`、`pfnKvmSplitIrqchipAddUpdateRTE/
  RemoveRTE/DeliverMsi`，内部都是 `KVM_IRQ_LINE`、`KVM_GET/SET_IRQCHIP`、
  `KVM_SET_GSI_ROUTING` ioctl 的薄封装；
- `DevPIC.cpp`：`picSetIrq` 直接转发 `KVM_IRQ_LINE`；save 时用
  `KVM_GET_IRQCHIP` 把内核 PIC 影子状态（irr/imr/isr/elcr……）拉回 VBox 结构；
- `DevIoApic.cpp`：IO-APIC 重定向表项（RTE）的增删改实时转发到内核 GSI 路由，
  MSI 投递走 `KVM_SIGNAL_MSI`；`KVM_EXIT_IOAPIC_EOI` exit 时
  `PDMIoApicBroadcastEoi` 通知设备模型做 level 触发源的 EOI 处理；
- `DevACPI.cpp`：MADT/ISO 描述按内核 irqchip 的实际接线生成
  （IRQ16–23 → GSI16–23，active high、level triggered）。

### 5.5 Hyper-V 半虚拟化（GIM on KVM）

VirtualBox 上游有 GIM Hyper-V 实现（`GIMR3Hv.cpp`，配合自家 HM 用）。
补丁做了三件事：

1. **功能裁剪**：`GIMR3Hv.cpp` 用 `KVM_GET_SUPPORTED_HV_CPUID` 查内核支持的
   Hyper-V 特性，VBox 只暴露交集（加了断言强制），不再假设"VBox 能模拟一切"——
   比如 SYNIC、STIMER 只有 KVM 能做，AutoEOI 相关的 APICv 暗示被关闭；
2. **新后端** `GIMHvOnKvm.cpp`（R3 初始化/save-restore）+
   `GIMAllHvOnKvm.cpp`（全上下文 MSR 读写）：所有 Hyper-V MSR
   （`0x40000000` 段）**透传给内核**（用户态 MSR 已使能），不再是 VBox 软件模拟；
3. **exit 处理**：`KVM_EXIT_HYPERV_HCALL`（未启用扩展 hypercall，直接回
   `GIM_HV_STATUS_ACCESS_DENIED`）、`KVM_EXIT_HYPERV_SYNIC`（只放行
   SCONTROL/SIMP/SIEFP 三个 MSR 写，其余 `AssertReleaseFailed`）。

### 5.6 嵌套虚拟化

Intel VMX 嵌套时，KVM 自己会处理 L2（guest 的 guest）。VBox 需要知道
"这次 exit 是从 L1 还是 L2 出来的"，以正确恢复嵌套 VMCS 状态。补丁用了一个
有创意的办法：读 `KVM_GET_STATS_FD` 暴露的**二进制统计**中 `guest_mode`
计数器——exit 时若计数非零，说明 exit 源自 L2 运行期间
（`KvmIsNestedGuestExit`）。这比解析嵌套 VMCS 干净得多，但依赖内核统计 ABI
（描述符表逐项 pread 解析，见补丁中 `KvmGetGuestModeOffsetFromStatsFd`）。

### 5.7 时间（TM）与 TSC

补丁对 TM 的改动围绕一个不变量：**TSC 必须单调、且 save/resume 后不跳变**。

- `TMAll.cpp` / `TMAllVirtual.cpp`：resume 路径上，VBox 与 KVM 后端有一份契约
  ——每次 VM exit 后 `vcpu state.tsc_val` 要及时写入宿主 TSC。但"VM 尚未执行过
  任何 guest 代码就被 poke"的场景下 `tsc_val` 从未被赋值，补丁改为**用
  host TSC + 当前 TSC offset 现算**再交给 TM，而不是信任 `tsc_val`；
- 提交记录还记载过一个 bug：`ResumeCpuTickOnAll` 计算错误导致 guest TSC 倒退，
  修复方式是在该函数里**重算一个全新的 TSC offset**；
- `nemHCLnxHandleTimers`：把 TM 的下一个虚拟定时器截止线编程进
  `kvm_run->kvm_clock` / halt-polling 相关字段，且只在截止线变化时重编程
  （避免每次 RUN 都 ioctl）；
- Intel Tiger Lake+ 的 split-lock 检测会让 guest 的跨缓存行 lock 指令挂在
  内核 mitigation 上，README 因此要求宿主 `split_lock_detect=off`。

### 5.8 线程唤醒（Poke）与信号

`nemR3NativeNotifyFF` 用 `RTThreadPoke`（`SIGRTMIN` 类实时信号）打断阻塞在
`KVM_RUN` 里的 vCPU 线程。三个坑补丁都处理了：

1. **不能 poke 自己**（`pVCpu->hThread == RTThreadSelf()` 时直接返回——
   当前线程正在处理 exit，重进 run-loop 时会重新检查所有 FF）；
2. **信号必须被消费**：`KVM_EXIT_INTR` 后若不 `sigtimedwait` 吃掉 poke 信号，
   下一次 `KVM_RUN` 会立即 `EINTR` 返回，vCPU 空转（`nemR3LnxConsumePokeSignal`）；
3. `thread-posix.cpp` / `include/iprt/thread.h`：为 poke 信号提供
   `RTThreadPokeSignal()` 查询接口。

### 5.9 其他细节修复（来自提交信息）

- A20 gate：VBox 6 时代 guest 运行时切换 A20 会崩（GRUB 触发），VBox 7 已修，
  补丁仍保留 A20 变化日志以便回归排查；full-irqchip 模式下无法支持 A20
  关闭期的内存环绕，故放弃该场景（DOS）；
- 中断 blocking 状态（`events.injected` 的 NMI/INT shadow）的置位/清除要与
  KVM 语义严格一致；
- alignment check（#AC）异常：存在使 CPU 完全卡死的 obscure 场景，策略是
  KVM 强制 exit 后**原样重新注入** guest；
- `SUPLib-linux.cpp`：默认 ramprealloc 时用 `MAP_POPULATE` 预映射，
  降低无内核驱动时缺页异常对启动性能的影响。

---

## 6. 36 个文件的完整改动清单

### 构建与配置（7 个）
| 文件 | 改动 |
|---|---|
| `Config.kmk` | KVM 相关宏定义（`VBOX_WITH_KVM`、`VBOX_WITH_KVM_IRQCHIP_FULL` 等） |
| `configure` | `--with-kvm` 等选项，条件定义宏 |
| `src/VBox/VMM/Makefile.kmk` | 新增 GIMHvOnKvm/GIMAllHvOnKvm 源文件 |
| `src/VBox/Main/Makefile.kmk` | Main 对 KVM 宏的条件编译 |
| `src/VBox/Runtime/Makefile.kmk`、`testcase/Makefile.kmk` | Runtime/测试的条件编译 |
| `src/VBox/HostDrivers/Support/Makefile.kmk` | Support 库调整 |

### NEM 核心（5 个）
| 文件 | 改动 |
|---|---|
| `src/VBox/VMM/VMMR3/target-x86/NEMR3Native-linux-x86.cpp` | **主体**：初始化、CPUID 协商、中断注入、exit 分派、Hyper-V exit、嵌套检测、定时器、poke 消费 |
| `src/VBox/VMM/VMMR3/NEMR3NativeTemplate-linux.cpp.h` | 与 ARMv8 后端共享的 Linux 通用逻辑（/dev/kvm 打开、版本检查等）的扩展 |
| `include/VBox/vmm/nem.h` | 导出 `NEMR3KvmGetCpuIdLeaves`、`NEMR3KvmGetHvCpuIdLeaves` 等 |
| `src/VBox/VMM/include/NEMInternal.h` | `nem.s` 状态扩展（stats fd、guest_mode 偏移、重定向表影子、定时器截止线等） |
| `src/VBox/VMM/VMMR3/PGMR3Phys.cpp`、`VMMR3.cpp` | NEM 使能时的物理内存路径微调 |

### 中断芯片与设备模型（6 个）
| 文件 | 改动 |
|---|---|
| `include/VBox/vmm/pdmdev.h` | `PDMPICHLP`/`PDMIOAPICHLP` 新增 `pfnKvm*` 回调族 |
| `src/VBox/VMM/VMMR3/PDMR3DevMiscHlp.cpp` | 上述回调的 R3 实现（KVM_* ioctl 薄封装） |
| `src/VBox/Devices/PC/DevPIC.cpp` | full 模式：IRQ 线转发内核、save 时拉回影子状态 |
| `src/VBox/Devices/PC/DevIoApic.cpp` | RTE↔GSI 路由双向同步、MSI 投递、EOI 广播 |
| `src/VBox/Devices/PC/DevACPI.cpp` | MADT/ISO 按内核 irqchip 接线生成 |
| `src/VBox/VMM/VMMR3/EMR3.cpp` | split irqchip 下保持 NEM 状态等待 SIPI |

### GIM/Hyper-V（5 个）
| 文件 | 改动 |
|---|---|
| `src/VBox/VMM/VMMR3/GIMHvOnKvm.cpp` | 新 R3 后端：初始化、save/restore（独立版本号 `0x1000` 避免与上游撞车）、MSR 注册 |
| `src/VBox/VMM/VMMAll/GIMAllHvOnKvm.cpp` | MSR 读写全上下文实现（透传内核） |
| `src/VBox/VMM/VMMR3/GIMR3Hv.cpp` | 功能位按 `KVM_GET_SUPPORTED_HV_CPUID` 裁剪 |
| `src/VBox/VMM/include/GIMHvInternal.h` | 内部声明与保存状态版本 |
| `src/VBox/VMM/VMMAll/target-x86/APICAll-x86.cpp`、`APICR3-x86.cpp` | APIC 与 Hyper-V/SYNIC 的交互点 |

### CPU/CPUID/XSAVE（4 个）
| 文件 | 改动 |
|---|---|
| `src/VBox/VMM/VMMR3/target-x86/CPUMR3CpuId-x86.cpp` | CPUID 叶子通过 KVM 掩码过滤 |
| `src/VBox/VMM/VMMR3/target-x86/CPUMR3-x86.cpp` | XSAVE 未使能时 resume 断言降级（VBox#69） |
| `include/iprt/x86.h` | 新增 CPUID 特性位定义 |
| `src/VBox/VMM/VMMAll/PGMAllBth-x86.cpp.h` | 影子页表路径在 NEM 下的微调 |

### 时间与运行时（5 个）
| 文件 | 改动 |
|---|---|
| `src/VBox/VMM/VMMAll/TMAll.cpp` | TSC 现算（不依赖 `tsc_val` 契约） |
| `src/VBox/VMM/VMMAll/TMAllVirtual.cpp` | resume 时 TSC offset 重算 |
| `src/VBox/Runtime/r3/posix/thread-posix.cpp` | poke 信号支持 |
| `include/iprt/thread.h` | `RTThreadPokeSignal()` 声明 |
| `include/iprt/mangling.h` | 符号改名表 |
| `src/VBox/HostDrivers/Support/linux/SUPLib-linux.cpp` | `MAP_POPULATE` 预分配 |
| `src/VBox/Main/src-server/HostImpl.cpp` | 宿主能力上报（NEM/KVM 使能分支） |

---

## 7. 重新实现的关键点（坑清单）

如果今天从零做同样的事，以下点是成败所在，按重要性排序：

### 7.1 状态所有权契约（最难）

`CPUMCTX` 字段在 VBox 与 KVM 之间来回转移所有权，靠 `fExtrn` 标记追踪。
**任何一个字段的同步漏掉或时机不对，表现都是"偶发 guest 崩溃/挂起"而非明确报错**。
重实现时必须：

- 建立一张完整的字段×方向×时机表（哪些在 RUN 前必须 SET、哪些 exit 后必须 GET、
  哪些 KVM 根本不管理）；
- 用 `kvm_sync_regs`（KVM_SYNC_X86_REGS/SREGS/EVENTS）减少 ioctl，但要清楚
  共享内存同步只在 `KVM_RUN` 边界生效；
- 对 inhibit（STI/MOV SS 阴影）和 NMI 注入语义做逐条对表，这是上游 stub 代码里
  断言最多的地方。

### 7.2 中断芯片模式选择

split vs full 不是性能取舍而是**能力取舍**：

- split：APIC 留在用户态 → 保留 VBox APIC 设备模型的全部能力（x2APIC、软件
  定时器、保存恢复），但 PIC 在内核导致实模式/DOS 行为和 A20 场景受限；
- full：内核全管 → 中断延迟最低、APICv 自动获得，但 save/restore 必须实现
  内核影子状态的导出导入（`KVM_GET/SET_IRQCHIP`），且 EOIs 广播、level 触发
  源的 EOI 语义一个不能错，否则 guest 磁盘/网卡随机丢中断。

补丁的答案是"两种都实现、configure 选"。重新实现时建议**先做 split**（改动面小），
再补 full。

### 7.3 CPUID 必须按 KVM 能力裁剪

裸把宿主 CPUID 给 guest 会在 KVM 不支持 FSGSBASE/AVX10 等指令时随机出
#UD。`KVM_GET_SUPPORTED_CPUID` 是唯一的真值来源，且没有数量查询 API，
要自己试尺寸；Hyper-V leaf 同理（`KVM_GET_SUPPORTED_HV_CPUID`）。

### 7.4 时间单调性

TSC 相关 bug 是这类项目里最难调试的（guest 表现为时钟跳变、TLS 证书报错、
文件系统时间戳错乱）。规则：

- save/resume 后绝不能让 guest TSC 倒退；`tsc_val` 契约在"vCPU 尚未跑过
  就被打断"时不可靠，要会现算（host TSC + offset）；
- guest halt 的唤醒延迟依赖定时器截止线正确编程进 KVM，否则 idle guest
  响应慢半拍。

### 7.5 信号生命周期

poke 信号漏消费 = vCPU 空转 100% CPU；漏屏蔽 = 宿主线意外醒来。
`sigtimedwait` 非阻塞消费 + 自线程短路两个细节必须配对出现。

### 7.6 exit 处理的完备性

`KVM_EXIT_HYPERV_*`、`KVM_EXIT_IOAPIC_EOI`、alignment-check 重注入这类
"理论上不该来"的 exit，**生产环境一定会来**。策略要明确：每个 exit 要么正确处理、
要么显式断言并给出可读日志，不能落到 `AssertFailed` 死代码。

### 7.7 可维护性设计

补丁每个版本要跟随上游 VBox 发版（git log 可见 2023 年以来十余次 rebase）。
支撑这一点的是：

- 单一开关 `VBOX_WITH_KVM` 完整隔离；
- 尽量把后端逻辑收在 NEM 文件内，跨层改动只加回调不加行为；
- 新文件的保存状态版本号刻意避开上游号段（`0x1000`）。

### 7.8 环境限制的前置校验

`split_lock_detect`、XSAVE 必需、x86_64-only、嵌套仅 Intel——这些应在
`NEMR3LnxInit` 阶段显式探测并给出可读报错，而不是留给 guest 随机挂起。

---

## 8. 专题：无内核驱动模式（driverless）下的网络机制

### 8.1 现状：为什么桥接和 NAT Network 不能用

VirtualBox 的网络后端是 PDM 驱动（`src/VBox/Devices/Network/`），宿主侧能力
依赖如下：

| 后端 | 驱动 | 是否需要 vboxdrv 系内核模块 |
|---|---|---|
| NAT | `DrvNAT.cpp`（内置 slirp，用户态协议栈） | **否** |
| NAT Network | IntNet + 内置 DHCP | **是**（IntNet 宿主侧走 vboxnetflt/vboxnetadp） |
| Bridged | `DrvIntNet.cpp` + trunk 到宿主网卡 | **是**（vboxnetflt 包过滤注入） |
| Host-only | IntNet + vboxnetadp 创建接口 | **是** |
| Generic | `ConsoleImplConfigCommon.cpp` `NetworkAttachmentType_Generic` 分支：按名字实例化任意 PDM 驱动并传属性 | 取决于驱动本身 |
| UDPTunnel | `DrvUDPTunnel.cpp`，VM 间 UDP 隧道 | **否** |

所以 driverless（`--disable-kmods`，KVM 后端的运行方式）下开箱即用的只有
**NAT** 和 **UDPTunnel**。README 的"只支持普通 NAT"即此意。

### 8.2 已验证可行的集成路径：外部 PDM 网络驱动 + Linux TAP

代码层面存在一条干净的扩展路径，不需要 VirtualBox 任何内核模块：

1. **PDM 支持运行时加载外部驱动模块**。`PDMR3Driver.cpp` 的 `pdmR3DrvInit`
   在加载内置 VBoxDD 之后，会遍历 CFGM 树 `/PDM/Drivers/*`，读取每个节点的
   `Path` 字段并用 `RTLdrLoad` 加载对应 `.so`，调用其
   `VBoxDriversRegister` 注册回调。模块里的驱动与内置驱动完全同权。
2. **Main 支持 CFGM 注入**。`ConsoleImplConfigCommon.cpp` 的
   `i_configCfgmOverlay` 把所有 `VBoxInternal/<路径>` extra data 原样映射成
   CFGM 节点。因此：
   ```shell
   VBoxManage setextradata "$vm" "VBoxInternal/PDM/Drivers/TapNet/Path" \
       /usr/lib/vbox-tapnet/VBoxTapNet.so
   VBoxManage modifyvm "$vm" --nic1 generic --driver1 TapNet \
       --property1 tapdev=tap0
   ```
   即可让虚拟机挂上一个自己编写的 TAP 网络驱动。
3. **驱动本体是一个 ~300 行的 PDM 驱动**，参照现成的 `DrvTAP.cpp`
   （Solaris `/dev/tap` 版，注册名 `HostInterface`）移植到 Linux：
   - 构造时 `open("/dev/net/tun", O_RDWR)` + `TUNSETIFF` 打开宿主 TAP 设备
     （属性里指定名字，或拿到 fd 后自己配）；
   - 起一个 async I/O 线程 `RTFileRead` TAP 口，收到的帧走
     `pDrvIns->pUpBase->pfnPollSet` 通知上层（网卡设备），发送方向实现
     `pfnSendBuf/pfnSendSgBuf` 写 TAP 口；
   - 配 promiscuous 标志由 TAP 设备自身保证（`IFF_PROMISC`）。
   VBox 自带的 `HostInterface` 驱动只实现了 Solaris `/dev/tap` 语义
   （`DrvTAP.cpp` 中的 `open("/dev/tap")`/I_STR ioctl），Linux 下该驱动
   虽被编译进 VBoxDD（`src/VBox/Devices/Makefile.kmk` 的
   `VBoxDD_SOURCES.linux` 包含 `DrvTAP.cpp`）但不能直接用——这是"移植而非
   新建"工作量小的原因。

桥接等价方案：宿主侧 `ip tuntap add tap0 mode tap` + 把 tap0 挂进现有 Linux
bridge（`ip link set tap0 master br0`），即得到无 vboxnetflt 的桥接。
Host-only 等价方案：tap + 宿主侧静态 IP + dnsmasq 提供 DHCP，复用 VBox 的
`VBoxNetworkAdp` 名字约定不需要，`DrvNAT` 的 slirp 端口转发（NAT 的
`--natpf1`）在 TAP 模式下不可用，需在宿主侧用 iptables/nftables 自己做 DNAT。

### 8.3 其他可选机制对比

| 机制 | 优点 | 代价 |
|---|---|---|
| Linux TAP + bridge（上节） | 功能等价桥接/host-only，内核原生 | 需要写/移植一个 PDM 驱动 |
| macvtap（代替 tap） | 免 bridge，直接绑物理口，性能略好 | guest 与宿主本身不通（macvtap 特性），配置面窄 |
| `DrvUDPTunnel`（已有） | 零开发，跨宿主连通 | 只是隧道，不提供宿主/外网连通；需成对配置 |
| AF_PACKET 直绑物理口 | 不创接口 | 要写内核态同款过滤逻辑（等价重写 vboxnetflt），不推荐 |
| virtio-net + vhost（未来） | 性能最好 | VirtualBox 设备模型无 vhost 数据面集成，工作量大 |

### 8.4 结论

KVM 后端本身的补丁**完全没有碰网络代码**（36 个文件无一在
`src/VBox/Devices/Network/`）。driverless 网络受限不是 KVM 后端的问题，
而是"哪些 PDM 网络驱动依赖 vboxdrv"的问题。最小成本的补齐方案是
**移植 `DrvTAP.cpp` 到 Linux `/dev/net/tun`，以 Generic driver + 外部模块
或直接进入 VBoxDD 的方式发布**；这能一次性补上桥接和 host-only 两个场景，
且与补丁的维护模型兼容（独立文件、独立开关、不碰上游逻辑）。

---

## 附：参考锚点

- 补丁：`patches/0001-NEM-Implement-KVM-backend.patch`
- KVM API 参考：<https://www.kernel.org/doc/html/latest/virt/kvm/api.html>
- Hyper-V CPUID 特性位：<https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/tlfs/feature-discovery>
- 应用验证源码树：VirtualBox 7.2.20 + 本补丁（构建见 §2）
