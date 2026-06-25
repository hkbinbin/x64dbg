# 当前反反调试方案的局限性分析

> 基于 2026-06 最新公开资料(ScyllaHide v1.4 文档、EAC/BattlEye 公开行为、CSDN 反调试综述等)对本 fork (`aclcwd.exe`) 现有方案做覆盖率体检。

## 我们目前覆盖的攻击面 ✅

| 反调试技术 | 我们的方案 | 实现位置 |
|---|---|---|
| `IsDebuggerPresent` / PEB.BeingDebugged | PEB hide 写 0 | `cmd-misc.cpp` HideDebuggerPebOnly |
| `NtGlobalFlag & 0x70` 检测 | PEB hide 清零 | 同上 |
| HEAP_TAIL_CHECKING / HEAP_FREE_CHECKING / HEAP_VALIDATE_PARAMETERS | PEB hide 清 ProcessHeap.Flags | 同上 |
| WoW64 PEB(x64 调 x86 程序) | HideWow64Peb32/64 | 同上 |
| `DebugBreakProcess`(远程 DbgUiRemoteBreakin) | 首字节 patch 成 `0xC3` | `PatchToRet` |
| `DbgBreakPoint` 远程触发 | 首字节 patch 成 `0xC3` | 同上 |
| `NtSetInformationThread(ThreadHideFromDebugger)` | 主动给所有线程调用 | `HideAllThreadsFromDebugger` |
| `FindWindowW("x64dbg", ...)` | Qt setApplicationName 改 "aclcwd" | `main.cpp` |
| `Process32Next` / `EnumProcesses` 找 "x64dbg.exe" | 改名 `aclcwd.exe` | `cmake.toml` |
| PE 资源 `GetFileVersionInfo` 读 ProductName | resource.rc 改 "aclcwd" | `resource.rc` |

**覆盖率估算**: 对中等水平 user-mode 反调试约能挡掉 60–70%。对接入 ScyllaHide 风格 hook 库的目标 0%(因为我们没动 ntdll syscall hook)。对 ring0 反作弊驱动 0%。

---

## 严重缺口 🔴(高优先级,容易被发现)

### 1. `NtQueryInformationProcess` 三大经典 InformationClass 未 hook

这是 **2025 年所有反作弊和保护壳的标配**:

| InformationClass | 值 | 探测内容 |
|---|---|---|
| `ProcessDebugPort` | 0x07 | DebugObject 端口 ≠ 0 说明被调试 |
| `ProcessDebugObjectHandle` | 0x1E | 同上,Vista+ 用 |
| `ProcessDebugFlags` | 0x1F | NoDebugInherit 标志 |
| `ProcessBasicInformation` | 0x00 | PBI.InheritedFromUniqueProcessId 反指父进程 |
| `ProcessBreakOnTermination` | 0x1D | BSOD 触发 |
| `ProcessHandleTracing` | 0x20 | 句柄追踪检测 |

**为什么我们的 PEB hide 挡不住**: PEB.BeingDebugged 是 user-mode 镜像,DebugPort 字段在内核 EPROCESS 里,user-mode 只能通过 `NtQueryInformationProcess(ProcessDebugPort)` 读;不 hook 这个 syscall,内核如实返回真的 DebugPort,**直接暴露**。

**何时被检测到**: 加载到目标进程后第一次 Tick(很多反作弊在 EntryPoint 之前注入 thread 跑探测)。

### 2. `NtQuerySystemInformation` 系统级探测

| InformationClass | 探测内容 |
|---|---|
| `SystemKernelDebuggerInformation` (0x23) | 内核态调试器(WinDbg local)是否启用 |
| `SystemProcessInformation` (0x05) | 枚举所有进程找调试器进程名(也能扫到我们改名后的 aclcwd,如果反作弊有 hash/PE 头特征库) |

### 3. `NtQueryObject(ObjectTypesInformation)` 句柄类型扫描

调试器附加时会在 NT 句柄表里留下 `DebugObject` 类型句柄。`NtQueryObject(_, ObjectTypesInformation)` 返回所有句柄类型的全局计数,**有 1 个 DebugObject 就说明这机器上有调试器活动**。这招对"找有没有任何调试器存在"非常有效。

### 4. 硬件断点(DR0-DR7)裸露

x64dbg 用 `bph` 下硬件断点会修改目标线程 CONTEXT.DR0-DR3 和 DR7。反作弊典型做法:

```cpp
GetThreadContext(hThread, &ctx);
if (ctx.Dr0 || ctx.Dr1 || ctx.Dr2 || ctx.Dr3) {
    // 检测到硬件断点
}
```

我们既没 hook `NtGetContextThread` 也没 hook `NtSetContextThread`,所以**只要你点了 `bph`,反作弊读自己的 CONTEXT 就看到 DRx 非 0**。ScyllaHide 的"Protect DRx"专门拦这个。

### 5. `NtClose` 无效句柄抛异常探测

经典手法:
```cpp
__try { CloseHandle((HANDLE)0xDEADBEEF); }
__except(EXCEPTION_EXECUTE_HANDLER) { /* 没异常说明被调试 */ }
```

无调试时 `NtClose` 对无效句柄返回错误码;**被调试时内核会触发 STATUS_INVALID_HANDLE 异常并交给调试器先处理**,如果调试器吞了异常(x64dbg 默认会吞),exception filter 不触发,程序就知道被调试。我们没动这块。

---

## 中等缺口 🟡(进阶反作弊会用)

### 6. INT3 (0xCC) 代码段扫描

x64dbg 默认软件断点是 `0xCC`。反作弊扫**自己进程的代码段**找 `0xCC`:

```cpp
for (BYTE* p = code_start; p < code_end; ++p)
    if (*p == 0xCC) panic();
```

**我们没改这块**:TitanEngine 的 SetBPX 写 0xCC,改不动(.lib 闭源)。

**绕过办法**:用户层面 — 在 GUI 里把"软件断点"设成默认硬件断点(`bph`),只下 4 个内,但被 DR 扫(见 4)又被发现。**死结**:要么 0xCC 扫,要么 DR 扫,二选一。ScyllaHide 同样无解。最终方案是去 ring0 用 KsDumper / hypervisor。

### 7. `OutputDebugString` 异常计数

```cpp
SetLastError(0);
OutputDebugStringA("test");
if (GetLastError() == 0) /* 调试器接收了 */;
```

x64dbg 接管了 `OUTPUT_DEBUG_STRING_EVENT` (debugger.cpp:2078),不会把异常透传,**GetLastError 不变**。检测命中。需要加 ForwardODS 开关(本项目 P3 还没做)。

### 8. 时间差检测 RDTSC / GetTickCount

```cpp
DWORD t1 = GetTickCount();
// 单步执行下面这条会很慢
__asm { nop };
DWORD t2 = GetTickCount();
if (t2 - t1 > 100) /* 被单步了 */;
```

我们完全没动 timing。ScyllaHide 有 `GetTickCount/64/GetLocalTime/GetSystemTime/NtQueryPerformanceCounter` 五个 timing hook。

### 9. TLS 回调里的反调试

很多保护壳在 `TLS_CALLBACK_0` 就跑 PEB / NtQueryInformationProcess 一轮。x64dbg **默认 TLS 回调下断点**,但断点本身是 0xCC,反作弊在 TLS 里扫自己 .text 就发现了 → 反作弊先于我们运行,再用前面 1-5 任意一条干掉自己。

### 10. 父进程 / 命令行检查

```cpp
PROCESS_BASIC_INFORMATION pbi;
NtQueryInformationProcess(GetCurrentProcess(), ProcessBasicInformation, &pbi, ...);
// pbi.InheritedFromUniqueProcessId == aclcwd.exe pid ?
```

反作弊查到父进程是 `aclcwd.exe` 同样判定异常,即使我们改了进程名 — 因为它**比对的是当前调试器 EXE 的特征**,反作弊可以拿父进程 PID → OpenProcess → 读那个进程的 PE 头去匹配静态特征。**改名只能挡字符串匹配,挡不住二进制特征比对**。

---

## 致命缺口 🔴🔴(ring0 / hypervisor 级别,user-mode 无解)

### 11. 内核态 `EPROCESS.DebugPort` 读取

签了名的反作弊驱动(EAC、BattlEye、Vanguard、ACE)在 ring0 直接读 `EPROCESS.DebugPort`,我们的 `NtQueryInformationProcess` 用户态 hook 即便加上也没用 — **没经过 ntdll**。

### 12. 内核 `ObReferenceObjectByHandle` 扫 DebugObject

驱动遍历所有 `DebugObject` 类型对象,反查持有者句柄,谁持有谁就是调试器进程。

### 13. PatchGuard 区域 / 内核回调 `PsSetCreateProcessNotifyRoutine`

反作弊驱动注册进程创建回调,**新进程一旦产生**就检查父进程 / 镜像 hash,我们的目标进程被启动时就被打标了。

### 14. PE 头特征 / 代码段 hash

反作弊厂商有"已知调试器特征库"。把 `x64dbg.dll` / `Qt5*.dll` / `TitanEngine.dll` 加载到目标进程(我们的 debuggee 不会加载这些,但**反作弊驱动遍历整个系统的进程模块表**),按 PE 头 timestamp、导出表布局、代码段 SHA256 匹配 → 直接发现是 x64dbg。

**改名挡不住**:即使 `x64dbg.dll` 改名 `aclcwd_core.dll`,导出函数表 `_dbg_dbginit` / 字符串常量 `"x64dbg"`(代码里至少 5 处明文,见 dbg/database.cpp:419 `"dd64"` 等)都是定位指纹。

### 15. EAC 2026 kernel rebuild 提速 3-4× 的签名扫描

[来源](https://rawcheats.com/answers/what-is-a-signature-scanner-in-anti-cheat) — EAC 2026 重写了内核扫描循环,3-4 倍速,Aho-Corasick 多模式匹配,**实时**比对内存。x64dbg 的内部字符串(`"x64dbg.com"`, `"TitanEngine"`, `"SetBPX"`, `"DebugUpdate"` 等)都是可签名的稳定特征,**user-mode 改名完全挡不住**。

### 16. Hypervisor 级反调试

VMProtect 3.x、Themida 2024+ 的 hypervisor 引擎可以走 VM-exit 直接检测 DRx、INT1/3 异常,完全绕过 user-mode。

---

## 我们这套方案的"舒适区"和"危险区"

**适合**:
- 自写的反作弊原型研究(目标进程是你自己写的)
- 中老年 MMO 端游(2018 年前的反作弊技术)
- 学术研究、CTF 题、加壳样本静态分析后的脱壳调试
- 大部分商业软件的 license 反调试

**不适合**:
- 主流竞技游戏 EAC / BattlEye / Vanguard(2024+)
- 网易 NP / 腾讯 TP / 完美 ACE 内核驱动版
- Themida + hypervisor 的高端壳
- 任何会做内存哈希比对的反作弊

---

## 改进路线图(按 ROI 排序)

| 优先级 | 项 | 预期收益 | 工作量 |
|---|---|---|---|
| ★★★ | **集成 ScyllaHide 插件**(已有 dp64 可直接复制) | 一次性补 #1-#10 几乎全部 user-mode 缺口 | 1 小时 |
| ★★★ | INI 配置项 ForwardODS,透传 OUTPUT_DEBUG_STRING_EVENT | 干掉 #7 | 30 分钟 |
| ★★ | 默认调成"软件断点优先使用硬件断点"(GUI 默认设置) | 部分缓解 #6,但暴露 #4 | 5 分钟 |
| ★★ | 改 x64dbg.dll / x64bridge.dll / x64gui.dll 名 + 同步 bridgemain.cpp 的 `#define dbg_lib` | 挡 EnumProcessModules 但挡不住 hash 比对 | 1-2 小时 |
| ★ | 编译时禁用 PDB,strip 符号表,去掉 `"x64dbg"` 字符串常量 | 削弱静态指纹 | 半天 |
| ★ | 套 VMProtect / Themida 给 aclcwd.exe 加壳(讽刺但有效) | 让逆向反作弊查不到我们是 x64dbg | 看授权 |
| (终极) | 上 ring0 — 集成 TitanHide 驱动(需测试模式 / EV 签名) | 挡 #11-#13 | 大工程 |
| (终极) | KsDumper-style hypervisor 调试 / DBVM / DBI 框架 | 挡 ring0 + hypervisor | 不现实 |

---

## 一行结论

**现状是个轻量级 stealth x64dbg,够对付绝大多数加密壳和原型外挂,但对 2024 年后的商业级反作弊(EAC/BattlEye/Vanguard/ACE)实质裸奔。**

**最划算的下一步:把 ScyllaHide 集成进 `aclcwd` 自带**,因为它已经覆盖了上面 #1-#10 的全部 user-mode 缺口,而且本身是开源的(GPLv3),把它的 `HookLibraryx64.dll` + 配置文件随发行包一起出就行,不需要自己重写。

---

## 参考资料

- ScyllaHide v1.4 Documentation: https://crackinglessons.com/wp-content/uploads/2020/02/ScyllaHide.pdf
- ScyllaHide 源码: https://github.com/x64dbg/ScyllaHide
- TitanHide(ring0 版): https://github.com/mrexodia/TitanHide
- Anti-Anti-Debug techniques(Checkpoint): https://anti-debug.checkpoint.com/
- 反作弊签名扫描器原理: https://rawcheats.com/answers/what-is-a-signature-scanner-in-anti-cheat
- CSDN 反调试综述: https://blog.csdn.net/qq_29709589/article/details/148716962
