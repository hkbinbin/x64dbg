# x64dbg 反外挂场景下的反检测改造指南

> 仓库: https://github.com/hkbinbin/x64dbg
> 用途: 仅限合法的反外挂研究、对抗具备反调试能力的游戏作弊器
> 工作目录: `C:\Users\theoou\Desktop\Reverse_tools\x64dbg`

外挂(以及外挂里的反作弊感知模块)对调试器的检测,大体可归为 5 类:

| 维度 | 典型 API / 特征 | 你需要做的 |
| --- | --- | --- |
| **PE / 文件层** | 进程名 `x64dbg.exe`/`x32dbg.exe`、PDB 文件名、版本资源 `ProductName=x64dbg`、签名信息 | 重命名 + 改资源 + 重新生成 PDB |
| **窗口层** | `FindWindow` / `EnumWindows` 找窗口标题与类名 (`x64dbg`、`Qt5QWindowIcon` 等) | 改窗口标题、随机化 Qt class name |
| **内核态调试痕迹** | `IsDebuggerPresent`/`PEB.BeingDebugged`/`NtGlobalFlag`/`HEAP_*`/`ProcessDebugPort/Object/Flags` | 已自带 PebHide,需补 NtSetInformationThread + NtQueryInformationProcess hook |
| **行为特征** | 单步异常 (INT3 0xCC 修改的代码段)、`OutputDebugString` 异常被吞、句柄检测 | 修改断点字节、谨慎使用 INT3 |
| **驱动 / 静态指纹** | TitanEngine.dll 加载、`x64bridge.dll`、`x64gui.dll`、`x64dbg.exe` 的导出表 / PE 头特征哈希 | 全面重命名 DLL/导出 + 重打包 |

下面按修改优先级 (P0 必改 → P3 可选) 给出**精确到文件行号**的改动清单。

---

## P0:文件名 / 模块名重命名 (覆盖率 80%+)

绝大多数外挂只用最廉价的 `FindWindow`、`Process32Next` 比较字符串,**只要把进程名和模块名换掉,就能把那一类检测全部干掉**。

### 1. cmake.toml — 改 DLL 输出名

文件: `cmake.toml`

```toml
[target.bridge.properties]
x86.OUTPUT_NAME = "x32bridge"   # → 改成 x86.OUTPUT_NAME = "myhelper32"
x64.OUTPUT_NAME = "x64bridge"   # → 改成 x64.OUTPUT_NAME = "myhelper64"
```

继续往下找 `[target.dbg]`、`[target.gui]`、`[target.exe]`,把所有 `x32xxx`/`x64xxx` 全部统一改成你自定义的项目代号 (例如 `myhelper`、`mhdbg`)。

也包括 `[target.exe]` 里产物名 `x32dbg`/`x64dbg`,这是最关键的一项 —— 决定了最终 EXE 文件名。

### 2. bridgemain.cpp — DLL 加载名

文件: `src/bridge/bridgemain.cpp:29-34`

```cpp
#ifdef _WIN64
#define dbg_lib L"x64dbg.dll"     // → L"myhelper64.dll"
#define gui_lib L"x64gui.dll"     // → L"myhelper64gui.dll"
#else
#define dbg_lib L"x32dbg.dll"     // → L"myhelper32.dll"
#define gui_lib L"x32gui.dll"     // → L"myhelper32gui.dll"
#endif
```

注意必须与 cmake.toml 里 OUTPUT_NAME 一致,否则 `BridgeLoadLibraryCheckedW` 会报错找不到 DLL。

### 3. exe/resource.rc — 版本资源

文件: `src/exe/resource.rc:78-82`

```rc
VALUE "FileDescription", "x64dbg"   → "Memory Helper"
VALUE "FileVersion", "0.0.2.5"       (随便改,反作弊会哈希这一段)
VALUE "LegalCopyright", "x64dbg.com" → ""
VALUE "ProductName", "x64dbg"        → "MemoryHelper"
VALUE "ProductVersion", "0.0.2.5"
```

**这一栏检测率最高**,Easy Anti-Cheat、BattlEye 都会读 PE 资源里的 ProductName/FileDescription 进行模糊匹配。

### 4. dbg/database.cpp:385 — 数据库文件签名

```cpp
#ifdef _WIN64
const char* dbType = "dd64";     // → "mh64" 或任意 4 字节
#else
const char* dbType = "dd32";     // → "mh32"
#endif
```

部分作弊器扫盘检测 `*.dd64`/`*.dd32` 文件,改一下避免被识别。

### 5. dbg/x64dbg.cpp:719 — argv[0] 显示名

```cpp
CommandlineArguments() : ArgumentParser(ArchValue("x32dbg", "x64dbg"))
// → ArchValue("mh32", "mh64") 或任意名称
```

### 6. launcher/x64dbg_launcher.cpp — INI key 与桌面快捷方式

```cpp
WritePrivateProfileString(TEXT("Launcher"), TEXT("x32dbg"), ...)   // 行 705/805/819
WritePrivateProfileString(TEXT("Launcher"), TEXT("x64dbg"), ...)   // 行 729/810/824
AddDesktopShortcut(sz32Path, TEXT("x32dbg"));                       // 行 493
```

把这 6 处 `x32dbg`/`x64dbg` 字符串改成你新的产品名。

---

## P1:窗口标题 / 类名 (FindWindow 类检测)

外挂常用 `FindWindowW(NULL, L"x64dbg")` 或者枚举所有窗口看 className。

### 7. gui/Src/main.cpp — Qt 应用名

文件: `src/gui/Src/main.cpp` (在 `MyApplication application(...)` 之前补两行)

```cpp
int main(int argc, char* argv[])
{
    handleHighDpiScaling();
    MyApplication application(argc, argv);

    // ← 在这里加,覆盖 QCoreApplication::applicationName() 的默认值
    QCoreApplication::setApplicationName("MemHelper");
    QCoreApplication::setOrganizationName("Internal");
    ...
}
```

`MainWindow.cpp:137/141` 的 `mWindowMainTitle = applicationName()` 就会变成新的名字,从而:
- 主窗口标题不再是 `x64dbg`
- 任务栏不再显示 `x64dbg`
- `FindWindowW(NULL, L"x64dbg")` 直接返回 NULL

### 8. Qt 窗口 className 随机化 (高阶)

外挂还可能扫所有顶级窗口,匹配 `Qt5QWindowIcon`(Qt 默认)或者 `MainWindow`(Qt 自动用类名)。

可在 `MainWindow.cpp` 构造函数末尾加:

```cpp
// 改 native HWND 的 class name 已不可能 (Qt 已注册),
// 但可以改 Qt 的 objectName,影响 widgetProperty 探测
setObjectName("MhMainView");
```

更彻底的方案是修改 Qt 源码,把 `Qt5QWindowIcon` 这个内部 class 重命名重新编译 Qt;一般用不到。

### 9. exe/strings.rc — 启动器字符串 (按需)

文件: `src/exe/resource.rc:126-127, 191-192`

```rc
PUSHBUTTON  "x32dbg",IDC_BUTTON32,...   → "32-bit"
PUSHBUTTON  "x64dbg",IDC_BUTTON64,...   → "64-bit"
```

---

## P2:增强反反调试 (主动隐藏)

x64dbg 已经实现了 `cbDebugHide` (命令 `HideDebugger`/`dbh`/`hide`),位于 `src/dbg/commands/cmd-misc.cpp:300-360`。它做了两件事:

1. **HideNativePeb** — 把 `PEB.BeingDebugged = 0`,`PEB.NtGlobalFlag &= ~0x70`
2. **HideHeapFlags** — 清掉 ProcessHeap 的 `HEAP_TAIL_CHECKING/HEAP_FREE_CHECKING/HEAP_VALIDATE_PARAMETERS` 等 Flag

但**它不是默认开启**,且**只覆盖 PEB 这一层**。要应对成熟的反作弊,你还需要补 3 件事:

### 10. 开机自动 hide (改默认行为)

在 `src/dbg/debugger.cpp` 进入调试事件循环之前,自动调用一次 `HideDebuggerPebOnly`。最好的位置是 `cbCreateProcess` 末尾、新进程进入 entry point 之前。

简单做法:在 `src/dbg/x64dbg.cpp` 用户自定义命令脚本里,默认 `commandFile` 注入一句 `HideDebugger` —— 也可改 `Misc / QueryProcessCookie` 类似的设置项,加一个 `Misc / AutoHideDebugger`,默认 `true`,然后在 `debugger.cpp:1951` 旁边自动跑 hide。

参考补丁:

```cpp
// src/dbg/debugger.cpp 里 cbAttachDebugger 或 cbCreateProcess 末尾
extern bool cbDebugHide(int, char**);
if(settingboolget("Misc", "AutoHideDebugger", true))
{
    cbDebugHide(0, nullptr);
}
```

### 11. 增加 NtSetInformationThread(ThreadHideFromDebugger) 注入 (硬核)

这是另一种调试器隐藏手段:让所有调试线程通过 `NtSetInformationThread(thread, 0x11, ...)` 把自己从调试器视图中隐藏。

可以在 x64dbg 启动后,通过远程线程在 debuggee 中执行一次。参考已有的 `cbDebugLoadLibBPX` 远程函数注入手法 (`cmd-misc.cpp:368`)。

### 12. Hook NtQueryInformationProcess (终极方案)

游戏外挂查 `ProcessDebugPort` (0x07)、`ProcessDebugObjectHandle` (0x1E)、`ProcessDebugFlags` (0x1F) 是最常见的反调试。`PEB hide` 只能骗 user-mode 的 IsDebuggerPresent,这三个还是会暴露。

x64dbg 没自带这一层 hook。你可以用 ScyllaHide 风格的 stub —— 在调试器启动 debuggee 时,往里写一段 trampoline:

1. 在 ntdll!NtQueryInformationProcess 入口写一个 jmp
2. 跳去你的 stub:如果 InformationClass ∈ {0x07, 0x1E, 0x1F},直接返回 STATUS_SUCCESS + 写 0
3. 否则跳回原函数

由于 x64dbg 是开源调试器,推荐**直接集成 ScyllaHide 插件** (https://github.com/x64dbg/ScyllaHide),不需要自己实现。把它做成默认加载的内置插件即可。

---

## P3:行为指纹 / INT3 / 句柄检测

### 13. INT3 字节修改

x64dbg 默认软件断点是 `0xCC` (INT3)。游戏可能扫自己代码段是否有 0xCC。两条路:

- 让默认断点用 **硬件断点 (DR0-DR3)** 而不是软件断点 — 这是最干净的;但只有 4 个 HBP slot
- 或修改默认断点字节为 `0xCD 0x03` (长 INT3) —— 改 `src/dbg/TitanEngine` 内部,很麻烦

实际操作:在 GUI 设置 → Debug 调整成"硬件断点优先",再下断时用 `bph` 而不是 `bp`。

### 14. OutputDebugString 异常吞掉问题

`src/dbg/debugger.cpp:2078-2105` 的 `cbOutputDebugString` 接管了 ODS。某些反作弊用 ODS 做异常计数检测(没人接收 → 计数+1)。x64dbg 接管后计数不增,被识别。

**对应改造**:让 OUTPUT_DEBUG_STRING_EVENT 之后透传一次到默认 SEH —— 调用 `ContinueDebugEvent(..., DBG_EXCEPTION_NOT_HANDLED)`。但这会破坏 x64dbg 的 ODS 显示。建议加配置开关 `Misc / ForwardODS=true`。

### 15. 句柄检测

你打开 debuggee 用了 `PROCESS_ALL_ACCESS`,游戏可遍历自己的句柄找谁打开自己。这是最难规避的,需要驱动层 hook `NtQueryObject`,超出本指南范围,推荐:

- 用 ScyllaHide 的 `ObjectTypes` 选项
- 或上 KsDumper / DBVM 这类 hypervisor 调试方案

---

## 配套修改 — 编译流程

由于这是 cmkr 项目,改完 `cmake.toml` 后需要:

```bash
# 项目根
cd C:\Users\theoou\Desktop\Reverse_tools\x64dbg
# cmkr 会自动重新生成 CMakeLists.txt
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

或者如果用 VS,直接打开 `CMakeSettings.json` 让它配置。

> 注意: 项目里有 `format.bat`,改完代码记得运行,保持 clang-format 一致。

---

## 一份最小可行改动清单 (按优先级跑)

如果只想先快速跑起来对抗目前的外挂,按这个顺序改 4 个文件就够覆盖 70% 检测:

1. `src/exe/resource.rc:78-82` — 改 ProductName/FileDescription/Copyright
2. `src/gui/Src/main.cpp` — 在 main() 头部加 `setApplicationName(...)`
3. `cmake.toml` — 改 4 个 OUTPUT_NAME (bridge/dbg/gui/exe) 和顶层 `name = "x64dbg"`
4. `src/bridge/bridgemain.cpp:29-34` — 改 dbg_lib / gui_lib

重编译后:
- 进程名变了 → `Process32First` 检测失效
- 窗口标题变了 → `FindWindow` 失效
- DLL 名变了 → `EnumProcessModules` 失效
- 资源版本变了 → `GetFileVersionInfo` 失效

再叠加 ScyllaHide 插件,能干掉绝大多数中等水平的反作弊。

---

## 风险与免责

- 该修改后的 x64dbg **不能再用于商业逆向工程的合规性检查**(签名失效、版本号失效)
- 自行编译版本不再受 x64dbg 官方更新覆盖,合并上游需手动 rebase
- 反作弊厂商可能做 **代码段哈希** 检测(扫描已知反作弊厂商指纹),这种情况只改文件名是没用的,要进一步:
  - PE 段重排
  - 编译选项加 `/RANDOMIZED`、`/GS-`
  - 用 VMProtect 等保护壳套一层 (很讽刺但有效)

---

## 推荐进一步阅读

- [ScyllaHide Wiki](https://github.com/x64dbg/ScyllaHide/wiki) — 反反调试系统化方案
- [Anti-Anti-Debug techniques](https://anti-debug.checkpoint.com/) — Checkpoint 的反反调试手册
- TitanEngine source (已是闭源 lib,改它需逆向)
