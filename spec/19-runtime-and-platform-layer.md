# 19 — Self-Hosted Runtime and Minimal Platform Layer

**Status:** RFC v0.1 (2026-10-13). Relates to `06` (OIM), `07` (formal safety, TCB), `08`
(std/core split), `09` (self-hosting), `11` (performance). Decision record: ADR-0013.

## 1. Goal

The Orin runtime MUST be **predominantly written in Orin**. Only a **minimal, explicit platform
layer** may be written in another language (C or assembly). The platform layer MUST be small
enough to be reviewed, specified and verified **separately** from the compiler and the rest of
the runtime. Rationale: every line of runtime code outside Orin is trusted computing base (spec 07);
moving it into Orin lets the same proofs that cover compiled programs (memory IR, verifier, formal
model) cover the runtime as well.

## 2. Layers

| Layer | Language | Contents | Assurance target |
|---|---|---|---|
| **L0 platform** (`platform/`) | C (or asm), freestanding style, no libc dependency beyond a declared list | raw memory: `page_alloc`/`page_free` (or `malloc`/`free` wrappers), byte load/store at an address, `memcpy`/`memmove`/`memcmp`; process: args, exit, abort; I/O: `read`/`write` on fds, open/close; clock; later atomics and threads | each function has a written contract (pre/post/frame) and is verified separately (e.g. Frama-C/WP, VST, CBMC) or, until then, exhaustively tested and fuzzed; kept under a hard size budget (target ≤ 1,000 lines, no data structures) |
| **L1 core runtime** (`core/`, Orin "core dialect") | Orin with a small set of *core intrinsics* (raw address type, load/store, size_of) usable **only** in modules the package manifest marks `core = true` | object header layout, `retain`/`release`/`make_unique`, allocation, arrays (push/pop/grow), strings (concat/append/compare/slice), struct slots, traps, the `ORIN_STATS` counters | proven to implement the operations of the formal memory model (refinement: each core function satisfies the corresponding Lean machine operation's specification); all core code also passes the MIR ownership verifier where it uses ordinary values |
| **L2 std** (`std/`) | safe Orin only | string utilities (`split`, `trim`, `indexOf`, `parseInt`, number formatting), array utilities, `fs`/`process`/`io` wrappers over L0, later maps, JSON, … | ordinary safe Orin: memory safety follows from the language guarantees; functional correctness by tests and optional contracts (spec 15) |

Rules:
- Safe user code can never name core intrinsics; using them outside a `core` module is a compile
  error. Annotations (spec 05) cannot generate core-intrinsic uses.
- The platform API is a **closed list** declared in one header/interface file; adding a function
  needs an ADR. L1/L2 may call L0 only through that list.
- The compiler links L1/L2 like any Orin code (whole-program, inlinable), so moving logic into
  Orin must not cost performance (spec 11: measure before/after each migration step).
- The generated program's TCB becomes: L0 + the C compiler/LLVM + the emitter (until translation
  validation) — not the object model or library logic.

## 3. Proof story (spec 07 layers)

1. **L0:** per-function contracts; verified with a C verifier or bounded model checker; the
   contracts are the axioms assumed by L1 proofs.
2. **L1:** Orin core functions refine the Lean memory machine (`formal/`): e.g. the
   implementation of `release` performs exactly the abstract `release` step (decrement, free at
   zero, release children) given L0's contracts. This turns today's "runtime is TCB" into a proof
   obligation.
3. **L2 and user code:** safe Orin; covered by the MIR verifier + formal model like any program.
Documentation MUST state for each runtime function which layer it is in and which of
"proven / statically checked / tested only / trusted" applies (spec 07 labelling).

## 4. Migration plan (incremental, never breaking the bootstrap)

- **R1 — std in Orin (no new language features):** move pure library logic currently in
  `runtime/orin_runtime.c` (split, trim, indexOf/includes, parseInt, int/usize→string, join,
  slice/concat helpers) into Orin modules compiled with every program; keep C versions only where
  Stage 0 needs them. Differential tests old vs new; benchmarks.
- **R2 — carve out L0:** split the remaining C into `platform/` (the closed list) and the object
  model; write L0 contracts.
- **R3 — core dialect:** add core intrinsics (raw address type, load/store, size_of, header
  access) restricted to `core` modules; reimplement the object model (retain/release/make_unique,
  allocation, arrays, strings) in Orin; the C object model is deleted. Stage 0 keeps its own C
  runtime (frozen) or links the generated C of L1.
- **R4 — proofs:** L0 contracts verified with a C verification tool; L1 refinement proofs against
  the Lean machine; update the safety-status table.

## 5. Non-goals / OPEN

- No garbage collector is introduced by this split (spec 06).
- Threads/atomics/async runtime design is OPEN (spec 12 #5); when added, the scheduler's
  low-level primitives belong to L0 and its logic to L1.
- Exact choice of C verification tool is OPEN.
