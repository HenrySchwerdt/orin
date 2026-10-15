# Standard library priorities for fast, reviewable implementation

Status: PO direction, 2026-10-15. Proposed APIs below are designs, not claims of implementation.
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

Finish `std:json` numeric support, including exponents, with a compatibility design for `JNum(int)`
consumers before changing public variants. Preserve exact integers rather than forcing every JSON
number through a floating representation. Specify out-of-range, non-finite, duplicate-key, and
depth-limit behavior.

Add ordinary decoder helpers that return field-path-aware errors: required/optional string, bool,
integer, numeric, array, and object fields; bounds and unknown-field policy should be explicit.
Application code should be able to write a small pure `decodeConfig(Json): Result<Config, DecodeError>`
and test it without files, environment, reflection, or code generation. Do not promise `parse<T>`
or introduce new annotations as a shortcut around the language freeze.

### Bounded process execution

An argument-array API with captured stdout/stderr, exit/signal information, explicit stdin, output
limits and a monotonic deadline. It should compose with `ProcessGrant` and avoid shell quoting as
the default abstraction. This directly helps compiler tools, tests, build systems and application
integrations. Correct macOS and Linux timeout behavior is an immediate acceptance case.

### File operations that make state changes reviewable

Directory entries and metadata, creating directories, renaming, temporary files, and atomic-write
helpers with explicit overwrite and durability semantics. Define symlink behavior and ordering.
Keep path normalization distinct from authorization; narrowing must not be widened by helpers.
Read/parse/validate should be separable, and a failed write should have documented observable state.

### Clocks and deadlines

A public monotonic clock, sleep, durations and deadline helpers with explicit units. Wall clock is
for timestamps; elapsed-time behavior must not depend on timezone or a wall-clock adjustment.
Do not silently disable deadlines when an external executable is absent.

## Priority 1: make integrations short and predictable

- **Encoding and URL utilities:** in progress in separate chats. Strict decoding, offsets, explicit
  padding/plus/UTF-8 semantics, duplicate query order, and linear buffer construction.
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

## Night-shift ordering

Finish the two running std tickets and review them. Next, portable bounded execution, then a JSON
numeric/decoder compatibility design. Use remaining time for a bounded implementation from that
design or the highest-impact file/clock gap. Do not expand into every item on this list overnight.
