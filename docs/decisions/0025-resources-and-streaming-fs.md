# ADR-0025: Resources (`File`) and the streaming `std:fs`

Status: accepted (2026-10-13). Implements the "Resources" row of ADR-0016 (spec 06 "External resources").
`std:fs` stays **unstable** until capabilities (ADR-0021; ADR-0016 two-stage freeze). MIR is v1.8.

## Decision in one paragraph
A *resource type* is a handle that is not a value. `File` (the only one in 1.0) can be a **function
parameter** (borrowed) and nothing else: not stored, returned, copied, captured, compared or converted. A
program obtains one only inside a **scope function** of `std:fs`, which opens the file, calls the program's
callback with the handle as the callback's *parameter*, and closes the file when the callback returns, on every
path. The rules are enforced twice: by the type checker (new errors E0450, E0451, E0452) and, independently, by
the MIR ownership verifier on the lowered code (a dedicated MIR type `MHandle` with a linear open/close
discipline), so a checker bug cannot produce a duplicated or escaping handle. At run time the handle is a
generation-tagged index that every operation validates, so even a verifier bug cannot become memory
unsafety, only a trap.

## Language surface
```ts
import { withFile, useFile, withFiles, useFiles, Read, Write, Append, File, FsError } from "std:fs";

const r: Result<int, FsError> = withFile("data.txt", Read, f => {   // f: File, a parameter of the callback
  let n = 0;
  while (f.readLine().isSome()) { n += 1; }
  return n;
});
useFile("out.txt", Write, f => { f.writeLine("hello"); f.flush(); });   // body returns nothing
withFiles("in.txt", Read, "out.txt", Write, (a, b) => copyLines(a, b)); // two files at once
```
`File.open(path, mode, f => ...)` (the spelling of spec 06 / ADR-0016) is not used: `File` is a built-in type
with methods, not a namespace for static functions, and a function `withFile` imported from `std:fs` is what
a capability-taking API will extend (`withFile(cap, path, mode, body)`). Two flavours exist because a generic
result `T` cannot be `void`: `withFile<T>` returns the body's value, `useFile` takes a body that returns nothing.
`withFiles`/`useFiles` open two files; they exist because a nested scope's closure may not capture the handle of
the outer one (E0452), so streaming from one file to another needs both handles as parameters of one callback.

**Types.** `FileMode = Read | Write | Append` (Read: the file must exist; Write: create or truncate; Append:
create if missing, every write at the end). `FsError = string` (alias, the human-readable message; a record or
union with variants is a compatible later refinement). `File` has the methods
`readLine(): Option<string>` (strips `\n`/`\r\n`, `None` at end of file), `read(n: usize): Option<string>` (up to
`n` bytes, `None` only at end of file when `n > 0`, `read(0)` is `Some("")`), `readAll(): string`,
`write(s: string): void`, `writeLine(s: string): void`, `flush(): void`. The whole-file functions
`readFile`, `writeFile`, `exists` keep their behaviour and signatures and are re-exported by `std:fs`.

**Errors.** The scope returns `Err(message)` if the file cannot be opened (the callback is not run), or if any
operation on the file failed (including the final flush/close). Individual operations stay simple (no `Result`
per `write`): the file remembers its *first* error (sticky, like `ferror`) and the scope reports it when it closes
the file; the callback's value is then discarded. A failed read looks like end of file to the callback. Using a
read-only handle for writing (or the reverse) is not a compile error (a handle has no mode in its type); the
operation does nothing and the scope ends with `Err("I/O error: Bad file descriptor")`.

**Capability readiness.** The handle parameter and the scope shape do not depend on how the file was
authorised. When ADR-0021 lands, the scope functions gain a capability parameter (and the `withFile` family may
also be reached as `cap.withFile(...)`); the `File` methods, the rules below and the MIR/verifier part do not change.
Opening goes through one runtime function (`orin_file_open`) and one platform function
(`orin_platform_stream_open`), the places where a capability check will be enforced.

## Rules (checker) and where they are enforced
Resource types: `File` only; it is exported by the internal module `std:fsraw` and re-exported by `std:fs`.

| Rule | Code | Where |
|---|---|---|
| a resource type inside another type: array element, `Option`/`Result`/generic type argument (declared or inferred), record/class field, union payload, result of a function type | E0450 | `resolveTy`, `decls.or`, `instFunc`/`instType` (types.or) with the type expression's span |
| a function (or closure) returning a resource | E0450 | `decls.or`, `resolveSig`, `checkArrow` (closure result), `resources.or` (generic instances) |
| a variable of resource type (`const g = f`, `let g: File = f`, a conditional...) | E0450 | `resources.or` (HIR pass) |
| a handle in any position except "argument of a call or method call": statement, branch of a conditional passed on, assignment, aggregate, match scrutinee... | E0451 | `resources.or` |
| a closure capturing a handle (also transitively through nested closures) | E0452 | `resources.or` at the `XClosure` capture list |
| `==`, `+` with a string, `.toString()` on a handle | E0410, E0405 | existing operator/method checks (`File` has no such operations) |
| the raw primitives (`std:fsraw`: `fileOpen`, `fileIsOpen`, `fileOpenError`, `fileClose`) | E0301 (unknown module) | importable only from library units (`$...`) |

The HIR pass (`compiler/check/resources.or`) runs on the checked HIR of every function, generic instances and
lifted closures included, so no inference path can bypass the declaration-site checks. The std:fs library
itself is the single exception: units named `$stdlib/fs` may bind `fileOpen(..)` to a local, because that is
what a scope function is; the local is still only passed to calls.

## MIR v1.8 and the verifier (the safety-critical part)
New MIR scalar type **`MHandle`** (C: `int64_t`; LLVM: `i64`). Structural rules (`compiler/verify/wf.or`, no
dataflow needed):
1. a handle local is defined **only** by `IBuiltin(Some(h), BFileOpen, ..)`: never by `ICopy`, `IMove`,
   `IBorrow`, a call result, a field/array read, arithmetic;
2. a handle is never an operand of `IStructNew`, `IArrayNew`, `ISetField`, `IArraySet`, `IArrayPush`,
   `IClosure` (capture), `IIface`, `IBinary` (no `==`), `IUnary`, `TBranch`, `TSwitch`, `TReturn`; a function's
   result type is never `MHandle`;
3. a handle is an operand of `ICall`, `ICallIndirect`, `ICallVirtual` (borrowed, class-checked against the
   callee's parameter) and of file builtins as their *first* argument; no other builtin sees a handle.

Dataflow rules (`state.or`, `rules.or`): states `Dead`, `Open` (this function opened it), `Param` (a handle
parameter: borrowed for the whole call), `MaybeOpen` (poisoned join). `BFileOpen` makes `Open` (an overwrite of an
open handle is an error: the file would never be closed); `BFileClose(h)` needs `Open` and makes `Dead` (closing a
parameter, a closed handle or a maybe-open handle is an error); every use needs `Open` or `Param` (use after
close is an error); **`TReturn` with an `Open` or `MaybeOpen` handle is an error**, not a warning. `TTrap` has no
obligation. A function that receives a handle can therefore only pass it on, and only the function that opened
it can close it, exactly once, on every path to a return. 31 hand-built MIR cases (positive and negative) are in
`compiler/tests/verify_main.or`.

## Runtime and platform
* **L0 platform layer** (all OS access): `orin_platform_stream_open/read/getc/write/flush/error/close` with
  ACSL-style contracts, an opaque `orin_platform_stream` (stdio `FILE*` plus a sticky error code). Contract
  tests: `platform/tests/platform_test.c` (`test_streams`: modes, errors, EOF, short reads, truncation, append,
  sticky errors, `/dev/full`, buffer boundaries). Status: tested only (they wrap the OS); no CBMC harness since
  the functions contain no logic beyond argument validation.
* **Runtime** (`runtime/orin_runtime.c`): a fixed table of 256 slots; a handle is `generation * 256 + slot`
  (positive), or `-errno` for a failed open. Every operation validates slot and generation and **traps**
  (`invalid file handle`) on a closed, stale or foreign handle; open fails with EMFILE when the table is full.
  `ORIN_STATS` gains `file_opens` and `file_closes` (equal when every scope closed its file).

## What "released on trap" guarantees
A trap (and `process.exit`) ends the process via `orin_platform_exit` -> `exit(3)`. The runtime registers an
exit hook (`files_at_exit`, through `orin_platform_at_exit`) that **flushes and closes every file still open**,
so bytes already handed to `write`/`writeLine` reach the file; the OS releases descriptors anyway. Not covered: a
kill by signal, `abort`, or a crash of the C runtime itself (buffered bytes are lost). The scope function's own
close (with error reporting) does not run on a trap: the trap message, not an `Err`, is the outcome.
`tools/test_tooling.sh` checks both the trap and the `process.exit` case against the bytes on disk.

## Concurrency (ADR-0017)
No tasks exist yet. The rules already match ADR-0017: a handle is not copyable, so it cannot be shared; moving a
handle *into* a task will need a deliberate extension (an owned-parameter mode for handles plus a task-spawn rule),
which this ADR does not provide. Until then a handle never leaves the scope of the callback.

## Limitations (accepted for 1.0)
* A nested scope cannot use the outer handle (no capture): use `withFiles`/`useFiles`, or pass the handle to a
  function. This is deliberate: allowing it needs lifetime reasoning ("the closure does not outlive the scope").
* At most 256 files open at once (a fixed table keeps the runtime free of allocation on this path).
* Text-oriented API: strings are byte strings; no seek, no binary type, no directory operations (post-1.0).
* The legacy `--legacy-codegen` backend does not support resources (it already rejects closures).
* Not mechanised: the handle rules are not part of the Lean model of the verifier (assurance row C14).

## Alternatives considered
* *Handle as a heap object with a finaliser*: spec 06 rules finalisers out; release would depend on the RC.
* *A checker-only guarantee*: rejected by the task and by ADR-0020 (the verifier must not trust the checker).
* *`File.open(path, mode, cb)`*: see above; revisit when capabilities are designed.
* *Per-operation `Result`*: noisy for the common loops; the sticky error gives the same information once.
