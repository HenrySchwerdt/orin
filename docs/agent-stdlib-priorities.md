# Standard library priorities for fast, reviewable implementation

Status: PO direction, 2026-10-15; factual refresh at main `8ec3679`, 2026-10-16.
Shipped slices are identified below; remaining API descriptions are proposals.
The goal is to reduce the amount of bespoke code, implicit policy, and evidence an application
author or coding agent has to reconstruct for every task.

## What makes a library useful to an agent

1. A small discoverable API with precise types and examples that compile.
2. Ordinary malformed input returns `Result` or `Option`, with a stable reason and position.
3. Deterministic behavior: specified ordering, duplicate handling, encoding, rounding, and limits.
4. Pure parsing/validation separated from I/O; grants stay explicit at external boundaries.
5. Stated allocation/complexity and limits, with measurements on representative inputs.
6. Executable evidence: known vectors, negative cases, round trips and behavioral invariants.
7. The same interface works from tests, normal applications, CLI tooling, and MCP inspection.

Do not add a new library solely to wrap a trivial expression. Prefer finishing a coherent vertical
slice (for example read config -> decode -> validate -> run bounded child -> inspect result).

## Priority 0: finish the foundations people will actually compose

### Structured data and configuration

Shipped opt-in libraries: [std:jsonnumber](std-jsonnumber.md) preserves validated
numeric lexemes and converts exact integral values to int; [std:jsonvalue](std-jsonvalue.md)
provides bounded document parse/write with strict UTF-8 and duplicate policies;
[std:jsondecode](std-jsondecode.md) adds sealed cursors, field paths, absent/null
distinction, exact inclusive integer bounds and explicit unknown-field policy.
The [pure config example](../examples/json_config.or) is executable without I/O
inside its decoder. Legacy `std:json` and compiler-internal JSON remain unchanged.

Remaining work includes explicit rounded float conversion (overflow/underflow
policy), legacy bridges and separately reviewed protocol-consumer migration.
Do not describe the RFC's float helpers as shipped or silently change existing
`JNum(int)` consumers. No `parse<T>` or new annotation shortcut is authorized by
these library slices. See the [JSON compatibility design](rfcs/json-completeness.md).

### Bounded process execution

Implemented: [`std:io.shellTimeout`](std.md#bounded-shell-execution-unstable) uses a native
monotonic deadline and process-group termination on macOS/Linux. It still runs a
shell command and inherits output; it does not supply argv-based execution,
captured stdout/stderr, explicit stdin, rich exit/signal results or output limits.
Those remain a coherent follow-up with `ProcessGrant`, bounded allocation and
portable deadline/cleanup tests.

### File operations that make state changes reviewable

Directory entries and metadata, creating directories, renaming, temporary files, and atomic-write
helpers with explicit overwrite and durability semantics. Define symlink behavior and ordering.
Keep path normalization distinct from authorization; narrowing must not be widened by helpers.
Read/parse/validate should be separable, and a failed write should have documented observable state.

### Clocks and deadlines

Public monotonic clock, sleep and deadline work is active in a separate chat,
not landed in this baseline. Existing `std:time` has wall time and duration/UTC
helpers; network resources already expose monotonic time for their operations.
Integrate the reviewed public clock result before timed task waits. Wall clock
is for timestamps; elapsed deadlines must survive wall-clock adjustments and
must not depend on an optional external executable.

## Priority 1: make integrations short and predictable

- **Encoding and URL utilities:** shipped [std:encoding](std-encoding.md) and
  [std:url](std-url.md): strict decoding, offsets, explicit padding/plus/UTF-8
  semantics and ordered query pairs. URL utilities cover components/query bodies,
  not full browser URL parsing.
- **HTTP client with HTTPS:** build on existing message parsing and bounded byte streams. Specify
  connection/read/total deadlines, response size, redirects and connection ownership; bind TLS to
  a reviewed implementation with certificate validation.
- **CLI argument parsing:** typed option definitions, short/long names, repeated values, `--`,
  actionable errors and generated help. The parser is pure; terminal rendering is a separate layer.
- **Logging and diagnostics:** structured fields and stable levels, explicit sinks, redaction,
  and testable output. Keep logs separate from application data and protocol stdout.

## Priority 2: reduce application-specific correctness work

- **Exact decimal arithmetic:** explicit scale/rounding, checked overflow and string conversion;
  suited to domain validation without assuming arbitrary business logic is formally proved.
- **Testing helpers:** deterministic generators with reported seeds, reusable law checks,
  structural JSON/byte assertions, snapshots with deliberate update operations, and useful failure
  paths. Use existing `@Test`; a new `@Property` annotation needs its own language decision.
- **CSV and public TOML parsing:** positions, limits and documented duplicate/type rules; finish
  coherent parsing/serialization APIs rather than expose the package manifest's restricted parser
  as if it were a complete TOML implementation.
- **OS randomness and UUIDs:** distinguish cryptographic OS randomness from deterministic test
  generation; capability and failure behavior must be explicit.
- **Database access:** maintained SQLite/PostgreSQL packages with bound parameters, typed row
  decoding and transaction scopes. Keep vendor-specific drivers out of the mandatory core stdlib.

## Acceptance checklist for each std ticket

- Public signature/error/ordering/complexity/allocation docs and a runnable example.
- Malformed and boundary inputs return the documented result, with no accidental trap.
- Resource exhaustion limits are explicit where input is untrusted or unbounded.
- Known vectors plus round trips or algebraic laws where meaningful; deterministic seeds.
- Contracts on/off and C/LLVM behavioral parity; no weaker verifier or capability policy.
- A small reproducible benchmark, separating measured results from asymptotic claims.
- MCP/source API discoverability and clean integration into the embedded std library.
- Honest proof status: tests and contracts are evidence; only supported verified claims are proofs.

## Current delivery order

Compose the shipped encoding/URL/JSON slices; review the active public clock work.
Next concurrency foundations are task trap cleanup/cancellation, interruptible
channel/join/I/O waits and monotonic deadlines, then a bounded scheduler/readiness
experiment. The [async/concurrency roadmap](roadmaps/async-concurrency.md) specifies
the ownership/recovery ADR gates and acceptance evidence. Existing OS-thread tasks
and CPU fork/join are not a nonblocking I/O scheduler. Async/await remains an
evidence-based later syntax decision under the language freeze, with no date or
new API-freeze declaration. Process capture/argv/output limits and the file gaps
above remain separate bounded std tickets, not prerequisites for adding syntax.
