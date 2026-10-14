# ADR-0027: Stage A of ADR-0021 -- enforced root capabilities for the standard I/O

Status: **accepted** (2026-10-13) for what is implemented and listed under "Enforced"; the parts marked *reserved* or
*not enforced* are not claims. Implements D1, D2 (the resource-handle part), D4a (handle identity) and D7 Stage A of
[ADR-0021](0021-capabilities-and-io-provenance.md). Needs **no new syntax** (ADR-0016): grants are resource handles
(ADR-0025) and std library functions. MIR is v1.9. `std:fs`, `std:process`, `std:io`, `std:time` and the new
`std:host` stay **unstable** until the project owner confirms the I/O freeze (ADR-0016 two-stage freeze).

## Decision in one paragraph

A program that performs I/O declares `function main(host: Host): void`. `Host` is a *resource type* with exactly the
rules of `File` (ADR-0025): it can only be a function parameter, passed on as a borrowed argument; it cannot be stored,
returned, captured, copied or compared (E0450, E0451, E0452), and the MIR verifier rejects the same things
independently. Only the runtime creates a `Host`, for `main`. From it the std library derives one **grant** per family
of operation through *scope functions* (`useFs(host, fs => ...)`), the same shape as `withFile`: the grant is the
callback's parameter and is revoked when the callback returns. Every std I/O function takes the grant that authorises
it as its **first argument** (`readFile(fs, path)`, `nowMillis(clock)`). Grants can be **narrowed**
(`useUnder(fs, "data", sub => ...)`, `useReadOnly`, `useArgsOnly`) and never widened. Every privileged runtime
operation validates the grant (live, right family, not denied by the host policy, inside its scope) and the platform
layer decides the path questions. `main(): void` receives no authority: every call that needs a grant is a **compile
error** (E0470).

## API

```ts
import { Host, useHost, useFs, withFs } from "std:host";
import { FsGrant, readFile, writeFile, withFile, useUnder, useReadOnly, Read } from "std:fs";
import { ProcessGrant, args } from "std:process";
import { StdioGrant, readLine, writeStdout } from "std:io";
import { ClockGrant, nowMillis } from "std:time";

function main(host: Host): void {
  useHost(host, (fs, proc, stdio, clock) => {     // all four root grants of the host policy at once
    console.log(args(proc).length.toString());
    useUnder(fs, "data", data => {                // a grant that only reaches `data/` (and below)
      const r = readFile(data, "data/in.txt");    // Ok
      const x = readFile(data, "/etc/passwd");    // Err("cannot read '/etc/passwd': outside the granted file scope")
    });
    useReadOnly(fs, ro => { writeFile(ro, "x", "y"); });   // Err("... the file grant is read-only")
  });
}
```

| Module | New / changed (all `UNSTABLE`) |
|---|---|
| `std:host` | `Host`; `withFs/useFs`, `withProcess/useProcess`, `withStdio/useStdio`, `withClock/useClock`, `withHost/useHost` (all four), `withArgsOnly/useArgsOnly` (process grant that cannot spawn) |
| `std:fs` | `FsGrant`; `readFile(fs, path)`, `writeFile(fs, path, data)`, `exists(fs, path)`, `withFile/useFile(fs, path, mode, body)`, `withFiles/useFiles(fs, ...)`, `withFileFs(fs, path, mode, (file, fs) => ...)` (the body gets the grant again: a closure cannot capture it), `withUnder/useUnder(fs, dir, body)`, `withReadOnly/useReadOnly(fs, body)` |
| `std:process` | `ProcessGrant`; `args(proc)`, (`exit(code)` needs no grant) |
| `std:io` | `StdioGrant`; `readLine(stdio)`, `readBytes(stdio, n)`, `writeStdout(stdio, s)`; `shell(proc, cmd)` moved to the process family (it is `Process.Spawn`) |
| `std:time` | `ClockGrant`; `nowMillis(clock)` |

`@Test` functions may take one parameter `host: Host` (the harness of `orin test` passes it); a test that needs no I/O
is unchanged.

## Design decisions and justification

**D1. Grants are resource handles, not a new ownership mechanism.** The type `TyGrant(kind)` sits next to `TyFile`; the
checker (`compiler/check/resources.or`), the MIR type `MHandle` and the verifier rules are shared. A grant has the same
lifecycle as a file: defined by an *opener* builtin (`BGrantFs`, `BGrantProcess`, `BGrantStdio`, `BGrantClock`,
`BGrantUnder`, `BGrantReadOnly`, `BGrantArgsOnly`, and `BFileOpen`), used as a borrowed argument, ended by one closer
(`BGrantRevoke`, `BFileClose`) on every path of the function that opened it. The new thing is only that an opener
*also takes a handle first* (the authority it is derived from: the Host, the parent grant, or the file grant for
`BFileOpen`), which the verifier checks (wf rule "handle-opening builtin: the first argument must be the authorising
resource handle") and the dataflow rule reads like any use (it must be `Open` or `Param`). Consequence: a narrowed grant
cannot outlive its parent's scope *by construction*, because both are scope parameters.

**D2. Scope functions, no `host.fs()` method returning a grant.** The task sketch `host.fs()` /
`fs.under("data/")` would return a resource, which ADR-0025 forbids (E0450). A returning form needs a lifetime /
ownership extension, which ADR-0021 D4a says must be reviewed separately. The scope form needs no new rule and gives
the same expressiveness. Cost (honest): a closure body cannot use a grant of the enclosing function (E0452). Take all
grants at once with `useHost`, pass grants as arguments to helper functions, or use `withFileFs` for nested scopes.

**D3. Root operation families.**

| Family | Grant | Operations (compiler-owned names) | Direction |
|---|---|---|---|
| Filesystem | `FsGrant` | `Fs.ReadFile`, `Fs.WriteFile`, `Fs.Stat`, `Fs.Open` (scope functions), `Fs.Read`, `Fs.Write` (file methods) | INPUT / OUTPUT / CONTROL |
| Process | `ProcessGrant` | `Process.Args` (INPUT), `Process.Spawn` (`shell`, CONTROL); narrowing `argsOnly` removes Spawn | |
| Stdio | `StdioGrant` | `Stdio.Read` (`readLine`, `readBytes`), `Stdio.Write` (`writeStdout`) | INPUT / OUTPUT |
| Clock | `ClockGrant` | `Clock.Now` | INPUT |
| Network | `NetGrant` | **implemented by ADR-0033** (was reserved): `Net.Bind`, `Net.Accept`, `Net.Connect` (CONTROL), `Stream.Read` (INPUT), `Stream.Write` (OUTPUT), exactly the operations of ADR-0021 Feasibility. No `std:net` exists; `TyGrant(5)`, the policy name `net` and the family bit are reserved so that Stage B adds the module and the platform operations without a new mechanism | |
| Environment | -- | no `std:env` exists. Reserved name `Env.Get` (INPUT) under the process family decision of the owner | |

**D4. `main()` without `host` has no authority: a compile error, not a runtime denial.** Every I/O function's first
parameter is a grant type, and no expression of a grant type can be written without a `Host`, so the call does not
type-check. The error says so (E0470, "needs a `FsGrant` as its first argument ... `main(host: Host)`"). Compile time
is preferable: it is total (every path), costs nothing at run time and shows in `orin check` and the OSIG. The runtime
check remains as defence in depth (D8).

**D5. Ambient output: `console.log`, `console.error` and `exit` need no grant.** Justification: they are the
language's own diagnostic channel (a trap prints through the same path and cannot be gated), they are used by every
program and library, and gating them would put a grant parameter in front of every `print` for no security gain that
survives the next point. **What this means, honestly:** a library that has *no* grant can still write bytes to stdout
and stderr, so a hostile or buggy library can leak data to wherever the process's stdout/stderr go (a log collector, a
terminal, a pipe), and can end the process (`exit`; any code can also trap). Stage A does **not** claim that code
without grants is incapable of observable output. Mitigations that do exist: the OSIG records every `console.*` call
site as a primitive OUTPUT event `Console.Write` with grant `ambient`, so a policy or a reviewer can see and diff them
(`PERFORMS_IO`, below); `std:io.writeStdout` (the binary / raw route that pairs with stdin) *does* need a `StdioGrant`.
A later ADR may add a deny mode ("no ambient output") if the owner wants one; it would be a compile-time policy
(strict profile), not a runtime one.

**D6. Host policy: everything the OS process has, minus `ORIN_DENY`.** The default grants are the full authority of the
process (so existing programs work once they take `host`). The environment variable `ORIN_DENY` is a comma-separated
list of `fs`, `process`, `stdio`, `clock`, `net`, `all`; the runtime reads it once, in `orin_cap_host_root`, through the
platform layer (`orin_platform_policy_load`). A malformed value (a typo, a space, an empty element, upper case) is
**rejected as a whole** and the program traps at start ("invalid ORIN_DENY"): a typo must never silently allow. A denied
family is still *handed out* so the program type-checks and runs; each operation reports the denial: an operation that
returns a `Result` returns `Err("... denied by the host policy (ORIN_DENY)")`, an operation that cannot report (`exists`,
`args`, `readLine`, `readBytes`, `writeStdout`, `shell`, `nowMillis`) **traps** ("capability denied: fs exists: ..."),
exit status 101. Rule: *Result gets Err, everything else traps; nothing fails silently with a plausible value* (an
"EOF" for a denied `readLine` or `false` for a denied `exists` would be indistinguishable from the real answer). The
environment variable was chosen over an `orin.toml [host]` section because the policy belongs to whoever *runs* the
binary (deployment), not to whoever wrote the package, and a compiled binary does not read manifests. It is read by the
platform layer, not by Orin code, so a program cannot change its own policy (no `setenv` exists in the std).

**D7. Path scopes: lexical normalisation plus symlink resolution, and the checked path is the opened path.** A narrowed
`FsGrant` stores a normalised absolute scope and its symlink-resolved twin. For every operation the runtime (1) makes
the argument absolute against the working directory and normalises it (`.`, `..`, repeated `/`; `..` at the root stays at
the root), (2) requires it inside the scope at a component boundary (`/a/b` contains `/a/b/c`, not `/a/bc`), (3)
resolves symbolic links of the longest existing prefix, requires the resolved path inside the resolved scope, and
**opens the resolved path**, not the original text, so a `..` behind a symbolic link cannot mean something different
for the check and for the use. Creating a file whose first non-existing component is a *dangling* symbolic link is
refused. Narrowing never widens: a requested scope outside the parent's yields a grant that reaches nothing; a requested
scope that contains the parent's keeps the parent's. The pure parts (`orin_platform_path_normalize`,
`orin_platform_path_within`, the policy parser) have contracts, contract tests and CBMC harnesses; the OS parts
(`path_absolute`, `path_real`) are tested only. Relative paths are resolved against the *working directory*, not against
the scope directory (a scope is a filter on the one path namespace, not a chroot).

| Attack | Result |
|---|---|
| `../` out of the scope, `/abs/outside`, `a/../../x` | refused by the lexical check |
| a symbolic link inside the scope pointing outside; a `..` after such a link | refused: the resolved path is outside |
| creating a file through a dangling link that points outside | refused |
| a link changed between check and open, a directory renamed in between (TOCTOU) | **not caught** (limitation) |
| hard links, bind mounts, `/proc/self/fd` magic links that alias outside files | **not caught** (hard links and mounts are invisible to path logic; `/proc/self/root` resolves to `/` and is refused) |
| an unscoped `FsGrant` opening `/dev/stdin`, `/proc/...`, device files | allowed: an unscoped file grant is the whole file system as the OS gives it |
| `shell(proc, cmd)` running anything | the process grant is **ambient authority in disguise**: a shell command can read, write and use the network regardless of every other grant. Narrow it (`useArgsOnly`) wherever spawning is not needed |

**D8. Handles are validated at run time.** A grant is `GRANT_TAG | generation << 8 | slot` in a table of 256 slots;
bit 40 makes a file handle numerically unusable as a grant. Every operation traps ("invalid capability grant (forged,
revoked, or of the wrong kind)") on a handle that is not live, has a stale generation or is of the wrong family. So a
compiler or verifier bug yields a trap, never an authority. 256 simultaneously live grants (each scope function holds
one) is a limit; exceeding it traps.

**D9. Moving into a task, never sharing (ADR-0017).** A grant (like a file) may be *moved* into a task once ADR-0017's
task spawn exists (an owned-parameter mode for handles plus a spawn rule); it can never be shared or copied. Nothing in
Stage A creates tasks, so the rule is only recorded here and in ADR-0021 Addendum A. *Implemented by the task stage:* see Q10
below and ADR-0017 Addendum A.

**D10. Forgery.** There is no constructor: `FsGrant {}` is E0400 ("a built-in resource type, not a record type"),
`const g = fs;` and `let g: FsGrant = ...` are E0450, an integer cannot become a grant (no conversion exists), the raw
primitives live in the internal module `std:fsraw` which user code cannot import (E0301), and a hand-written MIR that
defines a grant any other way is rejected by the verifier ("a resource handle is defined only by BFileOpen / BGrant*").

## Compile errors

| Code | Meaning |
|---|---|
| **E0470** | a std I/O function called without its grant (also `main()` without `host`), or with a non-grant first argument |
| **E0471** | a grant of the wrong family (`readFile(clock, ...)`), or `grantRevoke` of a non-grant |
| **E0472** | `main` takes a grant parameter other than `host: Host` |
| E0450 / E0451 / E0452 | reused unchanged for grants: stored / returned / aliased (E0450), used as a value (E0451), captured (E0452) |
| E0412 | `main` with any other parameter list |
| E0443 | `@Test` function with parameters other than `host: Host` |

## Verifier (MIR v1.9)

`BFileOpen` now takes the file grant as its first argument; new builtins `BGrantFs/Process/Stdio/Clock`,
`BGrantUnder/ReadOnly/ArgsOnly` (openers) and `BGrantRevoke` (closer); every std I/O builtin takes its grant first
(`takesHandle`). Rules: unchanged lifecycle (`Dead -> Open -> Dead`, `Param` borrowed), plus the structural rule that an
opener's first argument is a handle and its other arguments are not. Duplication (`ICopy`), storing (`IStructNew`,
`IArrayNew`, `ISetField`, closure capture), returning and comparing a grant are rejected exactly as for a file;
`compiler/tests/verify_main.or` has the new cases (grant duplicated, stored, returned, captured, defined by a call,
revoked twice, revoked while a parameter, not revoked on a path, derived from a closed parent).

## OSIG (`osig/0.1`, additive)

New node kind `Effect` (compiler-owned, id `~io:<Operation>`, `sig` = `<DIRECTION>; grant: <Grant>`) and new edge kind
`PERFORMS_IO` from the *enclosing function* of a call site to the Effect, `via` = direction (`INPUT`, `OUTPUT`,
`CONTROL`), evidence `MUST` for a direct call (`MAY` inside a closure body, like `CALLS`). Edges exist for the
primitive builtins, for the std scope functions (`withFile`, `withUnder`, `useFs`, ...: `Fs.Open`, `Fs.Narrow`,
`Host.Acquire`) and for `console.*` / `exit` (grant `ambient`). Transitive effect summaries (Stage B) are implemented: `MAY_PERFORM`
edges of `osig/0.2` and `orin effects` ([capabilities.md](../capabilities.md)). Not yet: data-flow
lineage, the grant chain, runtime events. **Absence of a `PERFORMS_IO` edge is not proof that a function performs no
I/O**: a call through a function value (`~unknown`) or into a callee outside the analysed package can hide one.

## Platform layer (L0)

New, with ACSL-style contracts in `platform/orin_platform.h`: `orin_platform_policy_parse/load`,
`orin_platform_path_normalize/within/absolute/real`. Contract tests (`platform/tests/platform_test.c`: 52 new checks,
including symbolic-link escapes), CBMC harnesses for the pure ones (`harness_policy_parse`, `harness_path_normalize`,
`harness_path_within`: canonical form, idempotence, agreement with the component-wise definition, transitivity of
containment so narrowing cannot widen). The grant *table* and the decisions that combine these answers are in the C
runtime (`orin_cap_*`, `runtime/orin_runtime.c`; `runtime/tests/runtime_test.c` has the new grant tests: forged / stale / wrong-family handles trap, scope, symbolic links, read-only, policy); they are trusted C.
The boundary check (`tools/check_platform_boundary.sh`) stays clean.

## Enforced / not enforced

| Statically (compile time) | At run time | Not at all |
|---|---|---|
| a std I/O call needs a grant of the right family (E0470/E0471); grants are resource handles (E0450-E0452); `main` shape (E0412/E0472); the MIR verifier re-checks duplication / escape / one revoke per path | handle validity (forged, stale, revoked, wrong family: trap); host policy (`ORIN_DENY`); read-only; path scope incl. symbolic links; `args` / `shell` flags | ambient `console.*` / `exit` (recorded in OSIG only); native code / FFI / raw syscalls (there is no FFI today; a modified compiler or a hostile native dependency can bypass everything -- OS isolation is needed, ADR-0021 "Native threat model"); TOCTOU, hard links, mounts; resource exhaustion; the C runtime and platform layer themselves (trusted: `docs/tcb.md`) |

## Bootstrap note (ADR-0014)

The grant API changes the signature of the std functions the compiler itself calls and the C ABI of the runtime
(`orin_fs_read_file(g, path)` ...), so the previous seed cannot compile the new compiler source. The seed was refreshed
through a **bridge**: a compiler built from the source state in which the checker, lowering, verifier, emitters and std
library implement the API but the compiler's own source still uses the old API (git commit `WIP: compiler support for
capability grants ...`), compiled by the previous seed with the *previous* runtime; the bridge compiled the migrated
source, `tools/bootstrap.sh` then reached `stage2.c == stage3.c`, and `stage2.c` is the new seed. `seed/SEED_INFO`
records this. The full chain old seed -> bridge -> new seed is reproducible from the two commits named there.

## Open questions for the project owner (before the std I/O freeze)

1. **Scope functions vs returned grants.** The scope form is forced by ADR-0025 and costs ergonomics (no capture of
   grants in closures). Is that acceptable for the freeze, or should a lifetime-checked "borrowed local" extension be
   designed first (it would allow `const fs = host.fs();` and narrowing in straight-line code)?
2. **Ambient output.** Keep `console.*` and `exit` grant-free (this ADR), or add a strict profile where they need a
   `StdioGrant` / `ProcessGrant`?
3. **Process grant = ambient authority.** `shell` bypasses every other grant. Keep one `Spawn` operation with
   `argsOnly` narrowing, or replace `shell` by an argv-based `spawn(proc, exe, args)` with an executable allow-list
   before the freeze (a freeze would otherwise cement `shell`)?
4. **`ORIN_DENY` as the only policy surface.** Is an `orin.toml` `[host]` section (documentation / default for
   `orin run`, not enforced by the binary) wanted, and should the policy also support allow-lists (`ORIN_FS_ROOT`)
   and per-family read-only (`fs:ro`)?
5. **Relative paths in scoped grants** resolve against the working directory (a filter, not a chroot). Confirm, or
   require scopes to be absolute / make relative paths scope-relative.
6. **`exists` on a denied path traps** (a `bool` cannot carry a denial). Confirm, or change the signature to
   `Result<bool, FsError>` before the freeze.
7. **Environment variables** (`std:env`) and **entropy**: which family do they belong to (process? a new `EnvGrant`)?
8. **Network (Stage B).** Confirm the reserved operation names and that listeners use the same scope-function shape
   (`withListener(net, port, l => ...)`, ADR-0021 D4a).
9. **Grant limit** (256 live grants) and the handle layout are runtime details; is a documented fixed limit acceptable?
10. **Tasks (ADR-0017).** The move-into-task rule for handles needs the owned-parameter extension for handles; schedule
    it with the task design, not with this stage. **Resolved with the task stage (2026-10-14, ADR-0017 Addendum A):** no
    owned-parameter mode for user code; `spawnFs(s, g, fsg => ..)` derives a grant of the same authority, moves it into the task
    through a one-shot token (MIR v2.1: `grantClone` opener, `grantMove` closer, `grantAdopt*` opener), and the task revokes it.
    The spawner's own grant stays valid; a task cannot capture a grant (E0483).
