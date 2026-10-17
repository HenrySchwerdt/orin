# Orin on Windows

Status: **WSL2 works today. A native Windows build does not exist yet**; this page gives the WSL2 steps and
the plan for the native port. Nothing in `runtime/core/` or `runtime/platform/` has been changed for Windows.

## WSL2 (works today)

Inside WSL2 Orin is the normal Linux release (linux-x86_64, or linux-aarch64 on Windows on Arm).

1. In an administrator PowerShell: `wsl --install -d Ubuntu` (Windows 10 2004+ or Windows 11), reboot when
   asked, then create the Linux user when Ubuntu starts. Check that it is WSL **2**: `wsl -l -v`
   (convert with `wsl --set-version Ubuntu 2`).
2. In the Ubuntu shell, install a C compiler and curl:
   ```sh
   sudo apt-get update && sudo apt-get install -y build-essential curl
   ```
3. Install Orin and check it:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/orin-lang/orin-lang/main/install.sh | sh
   export PATH="$HOME/.orin/bin:$PATH"     # the installer prints the right line if it is not on PATH yet
   orin doctor
   orin run ~/.orin/current/examples/hello.or
   ```
4. Work in the Linux file system (`~/projects/...`), not under `/mnt/c/...`: file access through `/mnt/c` is
   much slower and has different permission and line-ending behaviour. Edit with VS Code and its WSL
   extension (`code .` from the Ubuntu shell) or open `\\wsl$\Ubuntu\home\<you>` from Windows.

Run the installer inside WSL, not in Git Bash/MSYS2/Cygwin: `install.sh` refuses those shells on purpose
(there is no Windows package yet).

## Native port: plan

Not started. **It starts after capabilities Stage A lands**, because that work changes
`runtime/platform/orin_platform.h` / `.c` (and std): porting before would port an API that is about to change.
The first task of the port is to re-read the platform layer as it is then; the list below is for the
current layer and shows the size of the job.

### What `runtime/platform/orin_platform.c` needs

Every function defined in the current `orin_platform.c` (from `grep -n "^[a-z].*(" runtime/platform/orin_platform.c`) is listed; "portable" ones are plain C and need no change:

| Function | Windows work |
|---|---|
| `mem_find`, `fmt_u64`, `fmt_i64`, `double_to_exp`, `parse_double`, `write_line`, `flush` (the formatting and buffering helpers), `alloc`/`free`/`mem_*`, `exit`, `abort`, `at_exit` | portable C; no change |
| `init(argc, argv)`, `arg_count`, `arg` | Windows passes arguments in the ANSI code page. Build with a `wmain` (or `GetCommandLineW` + `CommandLineToArgvW`) and convert to UTF-8 so Orin strings stay UTF-8 |
| `getenv` | `getenv` is ANSI. Use `_wgetenv`/`GetEnvironmentVariableW` and convert to UTF-8 |
| `shell(cmd, n)` | uses `system()` with `WIFEXITED`/`WEXITSTATUS`, which do not exist on Windows (`system()` returns the exit code directly; it runs `cmd.exe`, so POSIX quoting in callers breaks). Decide the semantics first: `cmd.exe` string, or a direct `CreateProcessW` of an argument vector (preferred; needs a contract change) |
| `now_millis` | `clock_gettime(CLOCK_REALTIME)`: use `GetSystemTimePreciseAsFileTime` and convert from the 1601 epoch |
| `write(stream, ...)`, `stdin_read`, `stdin_getc` | stdio on Windows is text mode: LF becomes CRLF and 0x1A ends input. Call `_setmode(_fileno(stdout/stderr/stdin), _O_BINARY)` in `init`; decide what happens to the console code page (`SetConsoleOutputCP(CP_UTF8)`) |
| `error_message(code)` | `strerror` is fine for errno values; `GetLastError` codes would need `FormatMessageW` if a function returns them. The header asserts `EINVAL == 22` and `ENOMEM == 12`, true in the UCRT too |
| `file_read`, `file_write`, `stream_open` | `fopen` takes ANSI paths: convert the UTF-8 path to UTF-16 and use `_wfopen`; keep `"rb"`/`"wb"`/`"ab"`. Long paths (`\\?\`) and the share-mode default need a decision |
| `file_exists` | `stat` on a narrow path: use `_wstat64` or `GetFileAttributesW` |
| `stream_read`, `stream_getc`, `stream_write`, `stream_flush`, `stream_error`, `stream_close` | built on `FILE*`; portable once `stream_open` is |

Further places that are not the platform layer but will break on Windows (to be handled in the same port,
outside the scope of this page's "platform" list):
- `runtime/core/` uses GCC/Clang extensions (`__builtin_*`, `__attribute__((noreturn, cold))`,
  `__builtin_expect`). MSVC's `cl` does not accept them; this is the main argument for clang (below).
- The compiler's test runner and `orin test` use `/tmp/orin-test-N` and shell command lines; the wrapper
  quoting and temp-dir handling need a Windows variant.
- Path separators in the compiler's module resolution (`/` is accepted by the Win32 API, but printed paths
  and OSIG ids should stay `/`).

Threads (ADR-0017 stage 0) add `orin_platform_thread_create / join / exit / id`, `orin_platform_monitor_*` and the runtime lock, all on
`pthread` today. The Win32 backend needs `CreateThread` (or `_beginthreadex`), a `SRWLOCK` + `CONDITION_VARIABLE` pair (two queues) per monitor, a
`CRITICAL_SECTION` for the stdout buffer, `__declspec(thread)` / `_Thread_local` for the thread id, and `ExitThread` for `thread_exit`; the
runtime itself uses `__thread` and GCC `__atomic` builtins, which clang accepts. Until then std:task does not work on Windows.

Later capabilities (ADR-0021: file system, processes, network handles) will add more functions; each needs a
Win32 backend from day one, so the port should be structured as `runtime/platform/orin_platform_win32.c` beside the
POSIX file rather than `#ifdef`s inside one file, and `tools/check_platform_boundary.sh` must cover both.

### C compiler

| Option | Verdict |
|---|---|
| **clang (LLVM-mingw or the LLVM release, UCRT)** | **Recommended.** Accepts the GCC builtins/attributes the runtime uses, one compiler for the wrapper to expect (`CC=clang`), small download, same flags as macOS/Linux, links against the UCRT that ships with Windows 10+. Works with or without the Visual Studio Build Tools |
| mingw-w64 gcc | Also works with the existing runtime, which makes it a good fallback and the cheapest first milestone (MSYS2 `pacman -S mingw-w64-ucrt-x86_64-gcc`). Downsides: a separate toolchain world, and its own libc quirks (`printf` and locale flags) |
| MSVC `cl` | Not viable today: no `__builtin_*`, no `__attribute__`, and the code base relies on both. `clang-cl` (clang with MSVC flags) is the only MSVC-ABI route and is not needed unless users must link MSVC libraries |

Recommendation: target **clang with the UCRT** as the supported compiler, keep mingw-w64 gcc working as a
secondary option (it is cheap, since both accept the same C), and do not support `cl`. The wrapper looks for
`clang`, then `gcc`, and honours `CC`.

### Wrapper in PowerShell

`dist/orin` is a POSIX shell script, so the Windows package gets `bin\orin.ps1` plus a tiny `bin\orin.cmd`
shim (`@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0orin.ps1" %*`) so that `orin` works from
cmd.exe and PowerShell. It must mirror the same commands: `build`, `run`, `test`, `--version`, `doctor`,
and pass everything else to `libexec\orin.exe`. `doctor` checks the same four things (compiler, version,
layout, PATH) and prints Windows fixes (`winget install LLVM.LLVM`, `scoop install llvm`). Exit codes
must be forwarded exactly (`$LASTEXITCODE`), temp directories come from `New-TemporaryFile`-style unique
names, and arguments with spaces and quotes must survive. A native `orin.exe` launcher in C would remove
the PowerShell start-up cost and the execution-policy problems; consider it once the wrapper logic is
stable.

### Packaging

1. **Zip**: `orin-<version>-windows-x86_64.zip` with the same layout plus `bin\orin.ps1`/`orin.cmd`, a
   `.sha256` file and a line in `SHA256SUMS` (release.yml matrix gets a `windows-x86_64` entry).
2. **Scoop** (first, easy): a manifest `orin.json` in a bucket repo (`orin-lang/scoop-orin`) with
   `url`, `hash`, `bin`, `depends` (`llvm` or `mingw`), `checkver`/`autoupdate` from GitHub releases.
3. **winget**: a manifest PR to `microsoft/winget-pkgs` (`OrinLang.Orin`, installer type `zip` with a
   nested portable installer, or `portable`), generated with `wingetcreate` from the release. winget
   moderation takes days and requires a stable, signed-looking release; do it after Scoop works.
4. **install.ps1** (`irm .../install.ps1 | iex`) mirroring `install.sh`: detect arch, download, verify
   sha256 (`Get-FileHash`) and fail closed, install to `%LOCALAPPDATA%\Orin`, add to the user PATH.

Code signing (SmartScreen warns on unsigned executables) is an open question; see below.

### CI runner

`windows-latest` (Windows Server 2022/2025, x86_64) with clang from the runner image (LLVM is preinstalled)
or `msys2/setup-msys2` for mingw-w64. Windows on Arm (`windows-11-arm`) can follow. Steps: bootstrap
(`tools/bootstrap.sh` needs a POSIX shell, `python3`, `gzip`, `sha256sum`: run it under MSYS2/Git Bash, which
the runner has, or port the bootstrap to a PowerShell script), conformance suite, package, install test.
The seed is C, so the first Windows milestone is only: "the seed compiles with clang on Windows and
produces `orin0.exe`".

### Order of work

1. Wait for capabilities Stage A (platform layer API settles).
2. Make the seed, `runtime/core/` and the platform layer compile with clang on Windows (new
   `orin_platform_win32.c`); get the bootstrap to a fixed point (stage2 = stage3) on a Windows runner.
3. PowerShell wrapper and `doctor`; zip package; CI job and the install test for Windows.
4. Scoop bucket, `install.ps1`, then winget.

### Open questions
- Do we sign the Windows binaries (certificate cost, SmartScreen reputation)?
- Is `shell` kept as a `cmd.exe` string, or replaced by an argument-vector process API in the capabilities
  work (which would remove the quoting problem for every platform)?
- Minimum supported Windows (UCRT is in Windows 10+; Windows 7/8 are out of scope).
