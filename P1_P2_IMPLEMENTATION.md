# P1 + P2 实现说明 (反反调试增强)

## 改动文件清单

| 文件 | 行数变化 | 说明 |
| --- | --- | --- |
| `src/dbg/commands/cmd-misc.cpp` | +110 | 新增 `HideDebuggerExImpl` / `cbDebugHideEx` / `DebuggerAutoHideIfEnabled` / `PatchToRet` / `HideAllThreadsFromDebugger` |
| `src/dbg/commands/cmd-misc.h` | +2 | 暴露 `cbDebugHideEx` 与 `DebuggerAutoHideIfEnabled` |
| `src/dbg/x64dbg.cpp` | +1 | 注册命令 `HideDebuggerEx` / `dbhx` / `hideex` |
| `src/dbg/debugger.cpp` | +9 | `#include "commands/cmd-misc.h"`,在 `cbCreateProcess` / `cbLoadDll(ntdll)` / `cbAttachDebugger` 三个回调里挂钩 |

## 新增命令

```
HideDebuggerEx           # 别名: dbhx / hideex
```

执行内容(优先级递增):

1. `HideDebuggerPebOnly` — 已有,清 `PEB.BeingDebugged`、`PEB.NtGlobalFlag & 0x70`、清 `HEAP_TAIL_CHECKING / HEAP_FREE_CHECKING / HEAP_VALIDATE_PARAMETERS` 等堆 Flag
2. `PatchToRet("ntdll:DbgUiRemoteBreakin")` — 把首字节改成 `0xC3`,使 `DebugBreakProcess` 远程注入无效
3. `PatchToRet("ntdll:DbgBreakPoint")` — 把首字节改成 `0xC3`,挡住远程 `DebugBreak` 探测
4. `NtSetInformationThread(ThreadHideFromDebugger=0x11)` — 对 `ThreadGetList()` 拿到的所有线程调用,把它们从内核调试视角中隐藏

## 默认全自动 — 双击 x64dbg.exe 即生效

**本 fork 把两个 INI 开关的默认值都改成 `1`(true),用户开箱即用,无需任何手动配置。**

| INI key | 默认值 | 作用 |
| --- | --- | --- |
| `[Misc] AutoHideDebugger` | `1` | 仅 PEB 层,轻量级 |
| `[Misc] AutoHideDebuggerEx` | `1` | PEB + DbgBreak/RemoteBreakin patch + ThreadHide |

### 实现机制

`settingboolget(section, key, defaultValue)` 在 INI 里找不到 key 时会**自动写入默认值并返回**(见 `src/dbg/_global.cpp:301-310`)。我们在两处调用:

1. **DbgInit 末尾**(`src/dbg/x64dbg.cpp:958` 之后)主动读一次 —— 首次启动就把 `AutoHideDebugger=1` / `AutoHideDebuggerEx=1` 写进 `<userdir>/x64dbg.ini`,并打印一行 banner:
   ```
   [AutoHide] Default ON  (AutoHideDebugger=1, AutoHideDebuggerEx=1)
   [AutoHide] PEB / DbgUiRemoteBreakin / DbgBreakPoint / ThreadHide will fire automatically when you start/attach a process.
   [AutoHide] Set [Misc] AutoHideDebuggerEx=0 in x64dbg.ini to disable.
   ```
2. **运行时执行**(`src/dbg/commands/cmd-misc.cpp:451` 的 `DebuggerAutoHideIfEnabled`)再读一次,这时 INI 已有值,直接拿来用。

### 关闭方法

编辑 `<userdir>/x64dbg.ini`(默认在 `%APPDATA%/x64dbg/x64dbg.ini`):

```ini
[Misc]
AutoHideDebugger=0
AutoHideDebuggerEx=0
```

## 触发时机

| 时机 | 调用点 | ntdllReady | 行为 |
| --- | --- | --- | --- |
| 进程刚创建挂起态 | `cbCreateProcess` | false | 只做 PEB hide |
| ntdll.dll 加载完成 | `cbLoadDll` (modname == ntdll) | true | 触发 Ex (补丁 + ThreadHide) |
| 附加到已有进程 | `cbAttachDebugger` | true | 一次完成 PEB + Ex |

> 这种分层触发很重要:`cbCreateProcess` 时 ntdll 还没进入模块表,`valfromstring("ntdll:DbgBreakPoint")` 会失败。因此 `DebuggerAutoHideIfEnabled(bool ntdllReady)` 用一个布尔参数区分两种场景,让 PEB hide 早做、Ex 部分等 ntdll 就绪后补做。

## 代码走查 (P2 核心:`HideDebuggerExImpl`)

```cpp
static bool HideDebuggerExImpl()
{
    bool ok = HideDebuggerPebOnly(fdProcessInfo->hProcess);

    // DebugBreakProcess 在目标进程里 CreateRemoteThread(start=DbgUiRemoteBreakin),
    // 该线程入口默认是 `int 3`。改成 `ret` 后线程立即结束,不会触发断点事件。
    PatchToRet("ntdll:DbgUiRemoteBreakin");

    // DbgBreakPoint 是 `int 3` 一字节函数,KdInitSystem 等内核路径会通过它探测,
    // 替成 `ret` (0xC3) 后所有 software-int3 探测全部失效。
    PatchToRet("ntdll:DbgBreakPoint");

    // ThreadHideFromDebugger (0x11):该线程的异常不再上报给调试器,
    // anti-debug 代码常用 trap-self 验证调试器存在性,设这个 flag 后探测失败。
    int hidden = HideAllThreadsFromDebugger();
    return ok;
}
```

`PatchToRet` 用的是 x64dbg 自有的 `MemPatch(addr, &retByte, 1)`,会自动:
- 临时把内存页改成可写
- 写入 `0xC3`
- 把改动登记到 patch 列表(在 GUI Patches 视图可见,可一键还原)
- 恢复原 protection

`HideAllThreadsFromDebugger` 借助 x64dbg 已经维护好的 `threadList`(`thread.cpp:12`),里面每个 `THREADINFO.Handle` 都是 `OpenThread(THREAD_ALL_ACCESS,...)` 后的句柄,可以直接传给 `NtSetInformationThread` 不用自己再开。

## 怎么用

1. 重编译(改完代码后):
   ```bash
   cd C:\Users\theoou\Desktop\Reverse_tools\x64dbg
   cmake -B build -G "Visual Studio 17 2022" -A x64
   cmake --build build --config Release
   ```
2. **直接双击 `x64dbg.exe`** — 启动后 Log 区会出现三行 `[AutoHide]` banner,告诉你已默认开启
3. 在 x64dbg 里 File → Open / Attach 任意进程,Log 里会立即看到:
   ```
   [AutoHide] PEB hide applied
   [HideDebuggerEx] Patched ntdll:DbgUiRemoteBreakin @ 0x... -> ret
   [HideDebuggerEx] Patched ntdll:DbgBreakPoint @ 0x... -> ret
   [AutoHide] Extended hide applied; N thread(s) hidden
   ```
4. 不需要敲任何命令,无需编辑 INI;**首次启动会自动把开关写进 INI 持久化**
5. 仍可手动触发:命令栏敲 `dbhx` 立即重做一次三件套

## 局限和后续

- 两个补丁针对的是 user-mode 经典探测,如果反作弊有 ring0 驱动直接读 `EPROCESS.DebugPort`,这里挡不住 → 上 KsDumper / DBVM
- `NtQueryInformationProcess` hook(ProcessDebugPort/Object/Flags)没实现,推荐**集成 ScyllaHide 插件**而不是在主体里再写一份
- `NtClose` invalid handle 探测、`CloseHandle` 异常探测也建议交给 ScyllaHide
- 如果反作弊扫 `ntdll!DbgBreakPoint` 第一字节是不是 `0xCC`,那本方案反而暴露 —— 此时改用 `IAT hook` 或 `Detours` 插桩更隐蔽,但实现复杂度会高一个量级

## P1 + P2 对应于 ScyllaHide 的哪些选项

| 本实现 | ScyllaHide 对应项 |
| --- | --- |
| HideDebuggerPebOnly | PEB.BeingDebugged + NtGlobalFlag + Heap |
| Patch DbgUiRemoteBreakin | "DbgUiRemoteBreakin" |
| Patch DbgBreakPoint | "DbgBreakPoint" |
| ThreadHideFromDebugger | "NtSetInformationThread" |

ScyllaHide 还多 30+ 项 (NtQueryInformationProcess、NtQueryObject、Hardware Breakpoints 抗性、TLS 检测...)。如果你只是做反外挂 PoC,以上 4 项已能覆盖大部分游戏作弊器自检。
