# 5. Ownership, resources, capabilities and effects

Normative for the value model of the checker and lowering, `compiler/check/resources.or`, `check/call.or`, `check/decls.or`, the
std scope API (`library/std/host.or`, `fs.or`) and `compiler/analysis/effects*.or`. Sources: ADR-0010, 0011, 0021, 0025, 0027,
0033, 0037 and docs/capabilities.md. The memory-safety properties of the generated code are *not* restated here; they are in
[../memory-safety.md](../memory-safety.md) (S1 to S7, all `TESTED_ONLY` at the time of writing). Rule ids: `OWN`, `RES`, `CAP`, `EFF`.

## 5.1 Ownership and moves

**OWN-1.** The language has **no ownership, borrowing, lifetime or move syntax** and no references. Every value of a value type (chapter 3)
is observed as a private copy; a function parameter is an immutable value; assignment, argument passing, capture by a closure, storing
into a record or array, and sending to a task never share mutable state. Reference counting, copy-on-write and last-use moves are
implementation techniques with no observable semantics other than speed.
- Tests: `tests/run/value_semantics_record.or`, `tests/run/value_semantics_function.or`, `tests/run/array_value_semantics.or`,
  `tests/next/run/class_copy_independence.or`, `tests/next/run/closure_capture_snapshot.or`, `tests/next/run/map_value_semantics.or`.

**OWN-2.** *Owned parameters and moves (ADR-0010) are inferred and internal.* The optimiser gives each MIR function parameter a mode,
**borrowed** or **owned**, passes an argument by move when its local is dead after the call, and cancels retain/release pairs. These
are not part of the language: a program cannot observe them, except through the performance counters (`ORIN_STATS`, `movedCount()` /
`copiedCount()` of `std:task`). Every optimised function is re-checked by the MIR verifier, so a wrong inference is refused at compile
time (internal error, exit 70) and cannot produce a program.
- Tests: `tests/run/owned_param_semantics.or`, `tests/run/ownership_edges.or`, `tests/next/run/owned_param_linear.or`,
  `tests/next/run/consume_concat.or`, `tests/next/run/append_in_place.or`, `tests/next/run/forward_self_index.or`,
  `tests/next/run/fuse_not_fused.or`, `tests/concurrency/move_counts.or`.

**OWN-3.** Values cannot form reference cycles: values are immutable or copied on write and closures capture snapshots, so the object
graph of a task is always a DAG, and reference counting reclaims everything. A program that exhausts memory traps (`out of memory`,
exit 101).
- Tests: `tests/run/core_oom_trap.or`, `tests/run/core_oom_realloc_trap.or`, `tests/run/union_recursive.or`.

## 5.2 Resources

A **resource type** is a handle that is not a value. The resource types are `File` (`std:fs`), `Host` (`std:host`), the grants `FsGrant`,
`ProcessGrant`, `StdioGrant`, `ClockGrant`, `NetGrant`, and the network handles `Listener` and `Stream` (`std:net`). Their rules are the same.

**RES-1.** A resource can only be a **function parameter** (borrowed for the duration of the call). It cannot be stored in a variable
(`const g = f;`, `let g: File = f;`, E0450), in an array, record, class field, union payload, `Option`, `Result`, generic type argument or
function type (E0450, also through generics, aliases and inference), returned from a function, method or closure (E0450), compared,
concatenated or converted to a string (E0410, E0405), or constructed in source.
- Tests: `tests/next/errors/e0450_resource_alias_let_annotated.or`, `tests/next/errors/e0450_resource_alias_const.or`, `tests/next/errors/e0450_host_copied.or`,
  `tests/next/errors/e0450_grant_copied.or`, `tests/next/errors/e0450_resource_array_type.or`, `tests/next/errors/e0450_resource_record_field.or`,
  `tests/next/errors/e0450_resource_class_field.or`, `tests/next/errors/e0450_resource_union_payload.or`, `tests/next/errors/e0450_resource_option_type.or`,
  `tests/next/errors/e0450_resource_result_type.or`, `tests/next/errors/e0450_resource_in_some.or`, `tests/next/errors/e0450_resource_in_ok.or`,
  `tests/next/errors/e0450_resource_function_result.or`, `tests/next/errors/e0450_grant_returned.or`, `tests/next/errors/e0450_resource_closure_result.or`,
  `tests/next/errors/e0450_resource_arrow_result.or`, `tests/next/errors/e0450_resource_generic_identity.or`,
  `tests/next/errors/e0450_resource_generic_record.or`, `tests/next/errors/e0450_genclass_resource_argument.or`,
  `tests/next/errors/e0450_resource_conditional_alias.or`, `tests/next/errors/e0450_net_listener_stored.or`,
  `tests/next/errors/e0410_resource_compared.or`, `tests/next/errors/e0410_resource_concatenated.or`,
  `tests/next/errors/e0405_resource_to_string.or`, `tests/next/errors/e0405_resource_unknown_method.or`,
  `tests/next/errors/e0400_resource_constructed.or`, `tests/next/errors/e0400_resource_assigned.or`,
  `tests/next/errors/e0400_resource_in_record_literal.or`, `tests/next/errors/ts_dev_e0450_file_in_record.or`.

**RES-2.** A handle may appear in a call only as an **argument** of a call or method call. In any other position (an expression statement,
a branch of a conditional that is passed on, an assignment, an aggregate, a `match` scrutinee, ...) it is E0451.
- Tests: `tests/next/errors/e0451_resource_statement.or`, `tests/next/errors/e0451_resource_conditional_argument.or`,
  `tests/next/errors/e0450_resource_in_array_literal.or`, `tests/next/errors/e0450_resource_in_for_of_body.or`.

**RES-3.** A closure cannot capture a handle, also not transitively through nested closures or inside a call of an array method (E0452). A
callback of the scope API receives the handle as its parameter; code that needs two handles in a nested scope uses the `...Fs` forms
(`withFileFs`) or the multi-handle scope functions (`withFiles`, `useHost`) that pass them all as parameters.
- Tests: `tests/next/errors/e0452_resource_captured.or`, `tests/next/errors/e0452_grant_captured.or`, `tests/next/errors/e0452_host_captured.or`,
  `tests/next/errors/e0452_net_stream_captured.or`, `tests/next/errors/e0452_resource_captured_nested_scope.or`,
  `tests/next/errors/e0452_resource_captured_in_array_api.or`, `tests/next/run/cap_grant_chain_in_function.or`.

**RES-4.** A handle is obtained only inside a **scope function** of the std library. The scope function opens it, calls the program's callback
with the handle as the callback's parameter, and closes it when the callback returns, on every path. The scope returns `Err(message)`
if the handle cannot be opened (the callback is not run) or if any operation on it failed (a handle remembers its first error; individual
operations return no `Result`). A handle can be passed down to ordinary functions, recursion, and function values that take it as a parameter.
- Tests: `tests/next/run/fs_stream_basic.or`, `tests/next/run/fs_scope_errors.or`, `tests/next/run/fs_borrowed_handles.or`,
  `tests/next/run/fs_copy_two_files.or`, `tests/next/run/fs_many_files.or`, `tests/next/run/fs_exit_in_scope.or`, `tests/next/run/fs_trap_in_scope.or`,
  `tests/next/run/fs_stdin_to_file.or`, `tests/next/run/cap_grant_chain_in_function.or`.

**RES-5.** The raw primitives behind the resources (`std:fsraw`, `std:clock`, `std:core`, the task primitives) are internal modules that only
library code can import; user code importing them gets E0301 (unknown module).
- Tests: `tests/next/errors/e0301_resource_raw_import.or`, `tests/next/errors/e0301_grant_raw_import.or`, `tests/next/errors/e0301_net_raw_primitive.or`,
  `tests/next/errors/e0301_task_primitives_are_internal.or`, `tests/next/errors/e0301_core_ops_are_internal.or`.

## 5.3 Capabilities (grants)

**CAP-1.** A program that performs I/O declares `function main(host: Host): void`. `function main(): void` has **no authority**. The
accepted forms of `main` and their errors (E0472, E0412) are listed once, in EXP-19 (chapter 4). Only the runtime creates a `Host`, for `main`.
- Tests: `tests/next/errors/e0472_main_fs_param.or`, `tests/next/errors/e0412_main_host_and_more.or`, `tests/errors/e0412_main_with_params.or`,
  `tests/next/errors/e0470_main_without_host.or`, `tests/next/run/cap_pure_no_grants.or`.

**CAP-2.** From a `Host` the std library derives one **grant** per family of operations by scope functions that take a callback
(`useFs`, `useProcess`, `useStdio`, `useClock`, `useNet`, all at once with `useHost(host, (fs, proc, stdio, clock) => ..)`, and the `with...`
flavours that return the callback's value because a generic result cannot be `void`). A grant is the callback's parameter and is revoked when
the callback returns. Every std I/O function takes the grant that authorises it as its **first argument** (`readFile(fs, path)`,
`args(proc)`, `readLine(stdio)`, `nowMillis(clock)`).
- Tests: `tests/next/run/cap_fs_scope.or`, `tests/next/run/cap_grant_chain_in_function.or`, `tests/next/run/io_stdin_lines.or`,
  `tests/next/run/std_time_clock_builtin.or`, `tests/next/run/net_loopback.or`, `tests/run/std_fs.or`, `tests/run/std_process_args.or`.

**CAP-3.** A std I/O call whose first argument is not a grant of the right family does not type-check: no grant at all (including `main()`
without `host`, or a non-grant such as an integer) is E0470; a grant of another family (a `ProcessGrant` for `readFile`, the `Host` itself for a file
operation, a `NetGrant` for the wrong operation) is E0471. The check is at compile time and covers every path.
- Tests: `tests/next/errors/e0470_args_without_host.or`, `tests/next/errors/e0470_clock_without_host.or`, `tests/next/errors/e0470_stdin_without_host.or`,
  `tests/next/errors/e0470_net_without_grant.or`, `tests/next/errors/e0470_integer_is_not_a_grant.or`, `tests/next/errors/e0470_non_grant_argument.or`,
  `tests/next/errors/e0471_wrong_grant_kind.or`, `tests/next/errors/e0471_host_is_not_a_file_grant.or`, `tests/next/errors/e0471_net_wrong_family.or`.

**CAP-4.** Grants are resources (RES-1 to RES-3): they cannot be stored, copied, returned, put in a field, array or channel (`channel<FsGrant>` is
E0450), or captured by a closure or a task body (E0452, E0483).
- Tests: `tests/next/errors/e0450_grant_in_array.or`, `tests/next/errors/e0450_grant_record_field.or`, `tests/next/errors/e0450_grant_class_field.or`,
  `tests/next/errors/e0450_channel_of_grant.or`, `tests/next/errors/e0452_grant_captured.or`, `tests/next/errors/e0483_task_captures_grant.or`,
  `tests/next/errors/e0400_grant_forged_literal.or`.

**CAP-5.** A grant can be **narrowed** and never widened: `useUnder(fs, dir, ..)` restricts a file grant to a directory (path escapes such as `..`,
absolute paths and symbolic links leaving the directory are refused by the runtime), `useReadOnly(fs, ..)` removes writing,
`useArgsOnly(proc, ..)` removes the right to spawn. A narrowing that does not contain its parent yields a grant that reaches nothing; a narrowing of a
read-only grant stays read-only.
- Tests: `tests/next/run/cap_fs_scope.or`, `tests/next/run/cap_narrow_never_widens.or`, `tests/next/run/cap_trap_args_only_shell.or`.

**CAP-6.** `console.log`, `console.error` and `process.exit` need **no grant** (ambient authority): they are the language's diagnostic channel.
Code without a grant can therefore still write to stdout and stderr and end the process; this is not a claim of the capability model.
`std:io.writeStdout` and everything that reads input needs a `StdioGrant`.
- Tests: `tests/next/run/cap_pure_no_grants.or`, `tests/run/console_error.or`, `tests/run/std_process_exit.or`.

**CAP-7.** The host policy is the full authority of the OS process minus the families named in the environment variable `ORIN_DENY`
(comma-separated `fs process stdio clock net all`; any malformed value is rejected as a whole and the program traps at start). A denied family is still
handed out so the program type-checks; each operation reports the denial: an operation that returns a `Result` returns `Err("... denied by the host policy")`,
an operation that cannot report (`exists`, `args`, `readLine`, `readBytes`, `writeStdout`, `shell`, `nowMillis`) **traps** (`capability denied: ...`).
- Tests: `tests/next/deny/fs_open.or`, `tests/next/deny/fs_exists.or`, `tests/next/deny/process_args.or`, `tests/next/deny/process_shell.or`,
  `tests/next/deny/stdio_read.or`, `tests/next/deny/clock_now.or`, `tests/next/deny/clock_monotonic.or`, `tests/next/deny/net_listen.or`,
  `tests/next/deny/all_ok.or` (run by `tools/test_capabilities.sh` with the matching `ORIN_DENY`; they are not part of `conformance.sh`).

**CAP-8.** Grants are an enforced check in the runtime and the type system, not an operating-system sandbox. A `ProcessGrant` that can spawn is not
a sandbox for the child process, native code is not covered, and the summary of a function (EFF-1) says what code may do, not what it is permitted to do.
- Tests: none (a statement of scope; see docs/capabilities.md).

## 5.4 Effects

**EFF-1.** Effects have no source syntax. For every function the compiler infers the set of primitive effects it may perform transitively, with
the call chain that explains each one: `Fs.*`, `Process.*`, `Stdio.*`, `Clock.Now`, `Net.*`, `Console.Write`, `Host.Acquire`, and the `Unknown.*`
kinds for calls through function values of unknown origin. `orin effects` prints the result; the OSIG `MAY_PERFORM` edges, `orin diff`, hover and
`inspect` use the same analysis. A function value that is a parameter makes its caller parametric (the effects of the callback), not unknown.
- Tests: `tools/test_effects.py` (goldens `tests/osig/effects/app.effects.txt`, `tests/osig/effects/app.effects.json`), `compiler/tests/effects_test.or`,
  `tests/osig/effects/app`.

**EFF-2.** A function is **pure** if it performs no effect and calls only pure functions (relative to its function arguments); traps, bounds checks and
failed contracts are not effects. Purity is required in three places: a contract expression (`@Requires`, `@Ensures`, `@Invariant`, `@Decreases`, E0416;
chapter 7), the function and reducer of a `parallel()` pipeline (E0484, E0485; chapter 8), and `@Processor` functions (E0448; chapter 7).
- Tests: `tests/next/errors/e0416_io_in_contract.or`, `tests/next/errors/e0416_builtin_io_in_contract.or`, `tests/next/errors/e0416_io_transitive.or`,
  `tests/next/errors/e0416_clock_in_contract.or`, `tests/next/errors/e0416_closure_in_contract.or`, `tests/next/errors/e0416_function_value_param.or`,
  `tests/next/errors/e0416_mutating_method_in_contract.or`, `tests/next/errors/e0484_parallel_impure.or`, `tests/next/errors/e0484_parallel_impure_callee.or`,
  `tests/next/errors/e0484_parallel_function_value.or`, `tests/next/errors/e0485_parallel_reducer.or`.

**EFF-3.** `orin.toml` may restrict the effects of a module: `[effects]` (package default) and `[effects.<module>]` with `allowed = [..]`, where an entry is an
operation (`Fs.ReadFile`), a family (`Fs`), a family wildcard (`Fs.*`), `Unknown`, `Unknown.<kind>` or `*`. A module that may perform an effect outside its
allowance (transitively; a closure counts for the module that wrote it) is E0473 with the explanation path as notes; an entry that names no known effect is
E0474; a table for a module that does not exist is E0502; a malformed table is E0503. Unknown effects exceed every allowance that does not name `Unknown` or `*`.
Absent configuration means no restriction.
- Tests: `tools/test_effects.py` (policy cases), `compiler/tests/effects_test.or`, `tests/next/errors/e0502_unknown_module`,
  `tests/next/errors/e0503_manifest_unknown_key`.

## Gaps: rules without a test

- OWN-3: no test shows that a long-running program with value cycles *cannot* exist (the statement follows from the design); only the OOM trap is tested.
- RES-4: the guarantee that a handle is closed "on every path" is tested for return, `exit` and a trap inside the scope (`fs_exit_in_scope`, `fs_trap_in_scope`), not for a `?` early return in the callback.
- CAP-5: `useReadOnly` has a runtime test only inside `cap_narrow_never_widens`; there is no negative test that widening is impossible at the type level (there is no widening function).
- CAP-6: no test shows that a *library* function without a grant writes to stderr (only `main()` itself does); `process.exit` in a grantless `main` is `tests/run/std_process_exit.or`.
- CAP-7: a malformed `ORIN_DENY` (a typo, a space, upper case) trapping at start has no test in `tests/next/deny/`.
- CAP-8: statement of scope, no test applies.
- EFF-1: the conformance runner does not execute `orin effects`; its evidence is `tools/test_effects.py` and `compiler/tests/effects_test.or`, run by `tools/test_tooling.sh`.
- EFF-3: E0473 and E0474 have **no** test under `tests/errors` or `tests/next/errors`; they are covered only inside `tools/test_effects.py` (generated manifests).
