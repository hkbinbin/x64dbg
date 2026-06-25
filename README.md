# x64dbg (aclcwd fork — anti-anti-debug edition)

<img width="100" src="https://github.com/x64dbg/x64dbg/raw/development/src/bug_black.png"/>

> **Fork notice**: This is a fork of [x64dbg/x64dbg](https://github.com/x64dbg/x64dbg) with built-in anti-anti-debug modifications. The final executable is renamed to **`aclcwd.exe`** so anti-cheat / anti-debug code that scans for `x64dbg.exe` by name no longer matches. All upstream features are preserved — only stealth and auto-hide are added on top.

---

## Anti-anti-debug additions in this fork

The original x64dbg ships a manual `HideDebugger` (alias `dbh` / `hide`) command that toggles a handful of PEB fields. It's **off by default** and **only covers PEB**. This fork extends that into a full auto-hide pipeline that fires the moment a debuggee process is created or attached.

### 1. New command: `HideDebuggerEx` (aliases `dbhx`, `hideex`)

Runs four layers in sequence:

| # | Layer | What it does | Defeats |
|---|---|---|---|
| 1 | **PEB hide** (reused) | Clear `PEB.BeingDebugged`, `PEB.NtGlobalFlag & 0x70`, and the `HEAP_TAIL_CHECKING / HEAP_FREE_CHECKING / HEAP_VALIDATE_PARAMETERS` heap flags — applied to both the native PEB and the WoW64 PEB on x64 hosts. | `IsDebuggerPresent`, `CheckRemoteDebuggerPresent`, heap-flag probes |
| 2 | **DbgUiRemoteBreakin patch** | Overwrites the first byte of `ntdll!DbgUiRemoteBreakin` with `0xC3` (`ret`). Any remote thread injected via `DebugBreakProcess` returns immediately without raising a breakpoint. | `DebugBreakProcess`-based probes |
| 3 | **DbgBreakPoint patch** | Overwrites the first byte of `ntdll!DbgBreakPoint` with `0xC3`. Anti-cheat code calling this from a remote thread expecting an `EXCEPTION_BREAKPOINT` in our debug loop now silently no-ops. | Remote `DbgBreakPoint` triggers |
| 4 | **`NtSetInformationThread(ThreadHideFromDebugger=0x11)`** | Applied to every known debuggee thread via the cached per-thread handle from `ThreadGetList()`. Kernel stops routing that thread's exceptions to the debugger. | Trap-self anti-debug |

Both patches go through `MemPatch`, so the changes are recorded in the **Patches** view and can be reverted with one click.

### 2. Auto-hide on launch / attach

Two new INI keys (default **ON**) drive the pipeline automatically:

```ini
[Misc]
AutoHideDebugger=1     ; PEB layer only — light weight
AutoHideDebuggerEx=1   ; PEB + ntdll patches + ThreadHide  (recommended)
```

Wired into three callbacks in `src/dbg/debugger.cpp`:

| Callback | Stage | Behaviour |
|---|---|---|
| `cbCreateProcess` (line 1604) | ntdll not yet mapped | Runs PEB layer immediately so all the symbol-free hides go in early. |
| `cbLoadDll` when modname == `ntdll.dll` (line 1961) | ntdll just loaded | Runs the Ex part — `valfromstring("ntdll:DbgBreakPoint")` now resolves. |
| `cbAttachDebugger` (line 2273) | Attach | ntdll is already in the module list, so a single pass does everything. |

If the INI keys are missing, `settingboolget()` writes them back with the default `true`, so the user can later flip either to `0` to opt out and the choice persists.

### 3. Process / window / PE-resource rename

Anti-cheat code commonly walks `CreateToolhelp32Snapshot` / `Process32Next` looking for the literal string `x64dbg.exe`, or calls `FindWindowW(NULL, L"x64dbg")` to spot the GUI. This fork renames every user-visible identifier:

| Surface | Was | Now |
|---|---|---|
| Executable file name | `x64dbg.exe` / `x32dbg.exe` | `aclcwd.exe` (`cmake.toml:218-230`) |
| PE version resource (`ProductName`, `FileDescription`) | `x64dbg` | `aclcwd` (`src/exe/resource.rc:78-82`) |
| Qt `QCoreApplication::applicationName()` — drives main window title, taskbar caption, `QSettings` keys | `x64dbg` (Qt's default from `argv[0]`) | `aclcwd` (`src/gui/Src/main.cpp:172`) |

User directory follows the new name too: settings now live in `%APPDATA%\aclcwd\aclcwd.ini`.

DLLs (`x64dbg.dll`, `x64bridge.dll`, `x64gui.dll`) and the launcher `x96dbg.exe` keep their original names so the `bridgemain.cpp` LoadLibrary chain still works.

### 4. Launch-time banner

After the existing `Initialization successful!` line, the Log view now prints:

```
[AutoHide] Default ON  (AutoHideDebugger=1, AutoHideDebuggerEx=1)
[AutoHide] PEB / DbgUiRemoteBreakin / DbgBreakPoint / ThreadHide will fire automatically when you start/attach a process.
[AutoHide] Set [Misc] AutoHideDebuggerEx=0 in x64dbg.ini to disable.
```

…so you can tell at a glance whether the auto-hide is active.

### Files changed (versus upstream)

```
cmake.toml                       (exe target rename)
src/dbg/commands/cmd-misc.cpp    (HideDebuggerEx core, PatchToRet, HideAllThreadsFromDebugger, DebuggerAutoHideIfEnabled)
src/dbg/commands/cmd-misc.h      (export new symbols)
src/dbg/debugger.cpp             (auto-hide hooks at three callbacks)
src/dbg/x64dbg.cpp               (register HideDebuggerEx, log banner)
src/exe/resource.rc              (PE resource rename)
src/gui/Src/main.cpp             (Qt applicationName)
```

A consolidated diff lives in `P1_P2_implementation.patch` at the project root. See `P1_P2_IMPLEMENTATION.md` and `ANTI_DETECT_GUIDE.md` for the full design rationale.

### What this does **not** cover (and how we ship ScyllaHide to fill the gap)

The built-in hide handles roughly 4 of the 20+ user-mode anti-debug surfaces catalogued in the [ScyllaHide v1.4 docs](https://github.com/x64dbg/ScyllaHide). To close the remaining user-mode gaps without re-implementing them, this fork **bundles ScyllaHide v1.4 as a bundled plugin** with a custom `AntiCheat Strong` profile pre-selected. See [`LIMITATIONS.md`](LIMITATIONS.md) for the full attack-surface audit.

The plugin lives in `bin/x64/plugins/`:

```
ScyllaHideX64DBGPlugin.dp64   ; the plugin
HookLibraryx64.dll            ; the per-process hook payload it injects
scylla_hide.ini               ; profile config — defaults to AntiCheat Strong
```

The `AntiCheat Strong` profile (added at the end of `scylla_hide.ini`) turns on every user-mode hook relevant to game anti-cheat: `NtQueryInformationProcess` (ProcessDebugPort/Object/Flags), `NtQuerySystemInformation`, `NtQueryObject` (DebugObject scan), `NtSetInformationThread` (every call, not just once), `NtClose` invalid-handle, `NtGetContextThread`/`NtSetContextThread`/`KiUserExceptionDispatcher` (DR0-DR7 protection), `NtUserFindWindowEx`/`NtUserBuildHwndList`, all timing APIs (`GetTickCount`, `RDTSC` via `NtQueryPerformanceCounter`, etc.), and `OutputDebugString` forwarding.

The plugin loads automatically at startup (no menu interaction required). You'll see it in the Log view alongside the `[AutoHide]` banner. To opt out, delete or rename the `bin/x64/plugins/` files, or pick the `Disabled` profile via *Plugins → ScyllaHide → Options*.

### Still uncovered (need ring-0 or hypervisor)

- **Kernel-mode probes** that read `EPROCESS.DebugPort` directly — needs [TitanHide](https://github.com/mrexodia/TitanHide) (signed driver, test-signing or EV cert required)
- **INT3 (`0xCC`) byte scans** of the debuggee's own code — use hardware breakpoints (`bph`) instead, but ScyllaHide's DRx protection is needed too
- **PE-content / code-segment hash signatures** (EAC 2026 kernel scanner, BattlEye, Vanguard) — pack with VMProtect/Themida or do ring-0

### Build

Prerequisites: Visual Studio 2022 with the *Desktop development with C++* workload (provides MSVC, CMake, Ninja, Windows SDK). Then:

```cmd
git clone --recursive https://github.com/hkbinbin/x64dbg.git
cd x64dbg
build.bat all
```

The wrapper batch file calls `vcvars64.bat`, then runs CMake with the Ninja generator. Qt 5.12.12 is auto-downloaded on first configure. Final binary: `bin\x64\aclcwd.exe`.

---

## Screenshots

![main interface (light)](.github/screenshots/cpu-light.png)

![main interface (dark)](.github/screenshots/cpu-dark.png)

| ![graph](.github/screenshots/graph-light.png) | ![memory map](.github/screenshots/memory-map-light.png) |
| :--: | :--: |

## Installation & Usage

1. Download a snapshot from [GitHub](https://github.com/x64dbg/x64dbg/releases) or [SourceForge](https://sourceforge.net/projects/x64dbg/files/snapshots) and extract it in a location your user has write access to.
2. _Optionally_ use `x96dbg.exe` to register a shell extension and add shortcuts to your desktop.
3. You can now run `x32\x32dbg.exe` if you want to debug a 32-bit executable or `x64\x64dbg.exe` to debug a 64-bit executable! If you are unsure you can always run `x96dbg.exe` and choose your architecture there.

You can also [compile](https://github.com/x64dbg/x64dbg/wiki/Compiling-the-whole-project) x64dbg yourself with a few easy steps!

## Sponsors

<div align="center" markdown="1">

  <a href="https://sponsors.x64dbg.com/warp" target="_blank">
    <img alt="Warp sponsorship" width="400" src="https://raw.githubusercontent.com/warpdotdev/brand-assets/main/Github/Sponsor/Warp-Github-LG-02.png">
  </a>

  [**Warp, built for coding with multiple AI agents**](https://sponsors.x64dbg.com/warp)

<br>

[![](.github/sponsors/telekom.svg)](https://sponsors.x64dbg.com/telekom)

</div>

## Contributing

This is a community effort and we accept pull requests! See the [CONTRIBUTING](.github/CONTRIBUTING.md) document for more information. If you have any questions you can always [contact us](https://x64dbg.com/#contact) or open an [issue](https://github.com/x64dbg/x64dbg/issues). You can take a look at the [good first issues](https://easy.x64dbg.com/) to get started.

## Credits

- Debugger core by [TitanEngine Community Edition](https://github.com/x64dbg/TitanEngine)
- Disassembly powered by [Zydis](https://zydis.re)
- Assembly powered by [XEDParse](https://github.com/x64dbg/XEDParse) and [asmjit](https://github.com/asmjit)
- Import reconstruction powered by [Scylla](https://github.com/NtQuery/Scylla)
- JSON powered by [Jansson](https://www.digip.org/jansson)
- Database compression powered by [lz4](https://bitbucket.org/mrexodia/lz4)
- Bug icon by [VisualPharm](https://www.visualpharm.com)
- Interface icons by [Fugue](https://p.yusukekamiyamane.com)
- Website by [tr4ceflow](https://tr4ceflow.com)

## Developers

- [mrexodia](https://mrexodia.github.io)
- Sigma
- [tr4ceflow](https://blog.tr4ceflow.com)
- [Dreg](https://www.fr33project.org)
- [Nukem](https://github.com/Nukem9)
- [Herz3h](https://github.com/Herz3h)
- [torusrxxx](https://github.com/torusrxxx)

## Code contributions

You can find an exhaustive list of GitHub contributors [here](https://github.com/x64dbg/x64dbg/graphs/contributors).

## Special Thanks

- Sigma for developing the initial GUI
- All the donators!
- Everybody adding issues!
- People I forgot to add to this list
- [Writers of the blog](https://x64dbg.com/blog/2016/07/09/Looking-for-writers.html)!
- [EXETools community](https://forum.exetools.com)
- [Tuts4You community](https://forum.tuts4you.com)
- [ReSharper](https://www.jetbrains.com/resharper)
- [Coverity](https://www.coverity.com)
- acidflash
- cyberbob
- cypher
- Teddy Rogers
- TEAM DVT
- DMichael
- Artic
- ahmadmansoor
- \_pusher\_
- firelegend
- [kao](https://lifeinhex.com)
- sstrato
- [kobalicek](https://github.com/kobalicek)
- [athre0z](https://github.com/athre0z)
- [ZehMatt](https://github.com/ZehMatt)
- [mrfearless](https://twitter.com/fearless0)
- [JustMagic](https://github.com/JustasMasiulis)

Without the help of many people and other open-source projects, it would not have been possible to make x64dbg what it is today, thank you!

## Historical Donors

Before fully transitioning to [GitHub Sponsors](https://github.com/sponsors/mrexodia), this project received donations through BountySource. The original donation terms included an optional website link for donors who requested one at the time of donation. Links marked below reflect those requests. BountySource has since been shut down, so these records are reconstructed by hand. If you donated during this period and your username/amount is missing or incorrect, please reach out.

|Username|Amount|Date||Username|Amount|Date|
|-|-|-|-|-|-|-|
|sghctoma|$50|2015-04-19||dfrunza|$20|2017-01-30|
|overflow|$50|2015-04-25||ham3di|$100|2017-02-01|
|jl2id|$15|2015-04-29||johnny5|$5|2017-02-19|
|cypherpunk|$50|2015-05-02||David-Reguera-Garcia-Dreg|$90|2017-02-26|
|Aciid|$50|2015-05-05||[Alexandro Sanchez Bach](https://phi.nz)|-|2017-03-02|
|PI32|$15|2015-05-09||(unknown)|$6|2017-03-11|
|darkvapeur|$8|2015-05-21||fred26|$50|2017-04-08|
|fearless|$5|2015-05-24||gatesbillou|$20|2017-04-15|
|0x90|$10|2015-05-31||David-Reguera-Garcia-Dreg|$10|2017-04-24|
|acidflash|$50|2015-06-03||Adir|$20|2017-05-03|
|VackerSimon|$10|2015-06-14||ferbeb|$10|2017-05-17|
|Artic|$10|2015-06-29||(unknown)|$16|2017-06-04|
|[crystalidea](https://www.crystalidea.com/uninstall-tool)|$24|2015-07-10||androsa|$20|2017-06-11|
|jl2id|$10|2015-08-13||robersor|$25|2017-07-05|
|[PELock](https://pelock.com)|$115|2015-08-26||DDSTrainers|$10|2017-07-15|
|[tslater2006](https://github.com/tslater2006)|$20|2015-09-04||blaquee|$20|2017-08-27|
|Exidous|$20|2015-09-04||SmilingWolf|$15|2017-09-26|
|lupier|$40|2015-09-08||Alexander H.|$150|2017-10-11|
|Stef|$10|2015-09-15||gatesbillou|$25|2017-10-14|
|[d3v1l401](https://d3vsite.org)|$5|2015-10-06||t4rmo|$5|2017-10-18|
|Artur|$20|2015-10-24||joelcornu|$5|2017-10-27|
|RoBa|$100|2015-11-18||Adir|$35|2017-11-02|
|mr.tuna7331|-|2015-12-15||(unknown)|$10|2017-11-11|
|lupier|$90|2016-01-12||xdeng|$10|2018-01-04|
|fvrmatteo|$10|2016-01-21||v-p-b|$50|2018-03-21|
|willi.neu9|$10|2016-01-30||EmptyBrain|$50|2018-03-30|
|rithien|$100|2016-02-19||[mentebinaria](https://www.mentebinaria.com.br/)|$19|2018-04-12|
|ey|$20|2016-02-26||Mauro Bollini|$50|2018-06-07|
|clockwork|$10|2016-03-06||gatesbillou|$15|2018-06-17|
|codespy|$5|2016-03-23||Kirbiflint|$3|2018-06-22|
|test|$100|2016-03-28||Chisato Rokumiya|$20|2018-09-20|
|RomanGol|$10|2016-03-28||pengchang|$100|2018-10-24|
|fearless|$10|2016-04-24||younsunmin|$5|2018-11-18|
|Jack|$5|2016-05-17||EmptyBrain|$50|2018-12-27|
|willi.neu9|$30|2016-05-26||Yim|$10|2019-01-13|
|gatesbillou|$20|2016-06-02||[OALabs](https://www.youtube.com/c/OALabs)|-|2019-01-27|
|AGI|$155|2016-06-16||Lixinist|$10|2019-04-15|
|lupier|$100|2016-06-24||bloodmc|$50|2019-04-29|
|0x90|$50|2016-07-19||(unknown)|$20|2019-05-24|
|tr4nc3|$15|2016-07-31||masacate|$10|2019-07-10|
|MikeGuidry|$2500|2016-07-31||User Manuals|$5|2020-01-20|
|Alexander H.|$150|2016-09-09||Jim Conyngham|$50|2020-03-23|
|darkvapeur|$10|2016-10-04||Danya|$5|2020-06-08|
|h907308901|$5|2016-10-06||RooT|$160|2020-07-22|
|Adir|$20|2016-10-24||jadakiss9018|$2|2020-09-11|
|NicoG|$100|2016-10-27||samsonpianofingers|$15|2020-09-14|
|Angie|$150|2016-11-03||tpericin|$1337|2020-10-09|
|hulucc|$20|2016-12-02||nikkej|$100|2020-10-22|
|napcode|$10|2016-12-05||kha1ifaa|$10|2021-01-04|
|TechLord|-|2016-12-26||rikaardhosein|$20|2021-09-08|
|ayylmao5|$5|2017-01-01||Lukas21|$50|2021-09-15|
|affelwafro|$10|2017-01-03||Flavio Nardiello|$30|2021-12-01|
|FS|$40|2017-01-15||stevemk14ebr|$1000|2021-12-03|
|EmptyBrain|$50|2017-01-27||[ethical.blue](https://ethical.blue)|$19|2022-05-14|

_To all our early supporters: thank you for believing in this project before it became what it is today!_
