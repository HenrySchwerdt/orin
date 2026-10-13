# ADR-0017: Concurrency design — isolated tasks, transfer by move or copy, no shared mutable memory

Status: accepted as design (2026-10-13); implementation after the 1.0 core freeze (ADR-0016).
Resolves spec-12 OPEN #5 at the design level. Spec references: 06 (concurrency), 07 (race freedom).

## Model
- **Tasks are isolated.** Every heap object belongs to exactly one task. Reference counts stay
  **non-atomic** — single-task code pays nothing for concurrency, and the memory-safety proofs
  remain per-task.
- **Crossing a task boundary is a `send`:** the value is either **moved** (the runtime checks that
  the value graph is uniquely owned — all reachable counts are 1 — and transfers it without
  copying) or **deep-copied** otherwise. Semantically both are a value copy (spec 03), so the
  choice is unobservable except in performance; `ORIN_STATS` reports moves vs copies.
- **No shared mutable memory exists**, hence no data races by construction (spec 07 "race on
  unsynchronized shared mutable memory" is excluded structurally, not by a checker).
- **Resources** (ADR-0016) can be moved into a task but never shared or copied.

## API (no new syntax; no async/await colouring)
```ts
import { scope, channel } from "std:task";

const results = scope(s => {                 // structured: all tasks finish before scope returns
  const a = s.spawn(() => expensive(1));     // closure captures by value (ADR-0011)
  const b = s.spawn(() => expensive(2));
  return [a.join()?, b.join()?];             // join(): Result<T, TaskError> (trap in task -> Err)
});

const (tx, rx) = channel<Msg>();             // illustrative; final shape: a record { send, receive }
tx.send(msg);                                // send = move-or-copy transfer
match (rx.receive()) { Some(m) => ..., None => ... }   // None when all senders are gone
```
- `scope` guarantees no task outlives it (structured concurrency); a trapping task yields
  `Err(TaskError)` at `join`, siblings are cancelled at the scope boundary (cooperative).
- Blocking operations (I/O, `join`, `receive`) block only the calling task; the runtime uses an
  M:N scheduler in L1 (Orin) over L0 thread/futex primitives (spec 19).
- `parallelMap(xs, f)` (spec 08) is a library function on top of `scope`.

## Consequences for verification
- The Lean memory model stays per-task; a separate small model proves that `send` (move of a
  uniquely owned graph, or deep copy) preserves per-task well-formedness and never creates
  cross-task aliases.
- MIR gains no concurrency instructions; `send`/`spawn` are runtime calls whose ownership effect
  is "consume the argument" (verifier rule like an owned parameter).

## Post-1.0 options (not decided)
`Shared<T>` for deeply immutable values with atomic RC (opt-in, explicit type) for large
read-only data; async/await syntax if blocking tasks prove insufficient.
