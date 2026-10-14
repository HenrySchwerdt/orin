# ADR-0030: A provable standard library on a minimal trusted runtime

Status: accepted (2026-10-13). Requested by the project owner: a std that is provable from the
ground up, capability-gated for every input/output so that no code can escape, a large std
(sockets, HTTP, MCP, JSX), every part bounded by invariants, and as little C as possible.
Related: spec 19 (runtime layers L0/L1/L2, R1–R4), ADR-0021/0027 (capabilities), ADR-0020 (status
vocabulary, sequencing), ADR-0028 (contract quality), ADR-0029 (refusal protocol), ADR-0015
(contract and class standard).

## Context

Today's trusted C:

| Part | Lines | Assurance |
|---|---|---|
| `platform/` (L0, closed list) | about 610 incl. header contracts | memory/find/format primitives CBMC-bounded; I/O tested only |
| `runtime/` (object model, arrays, strings, traps, I/O shells) | about 1,570 | tested only (ASan/UBSan, differential) |

The language guarantees (MIR ownership verifier, Lean model) stop at the C runtime: retain/release,
copy-on-write, array growth and string operations are **assumed** correct. That is the largest gap
in the proof chain.

The std has three places: `std/` (prelude, safe Orin), `stdlib/` (`fs`, `json`, `path`, `time`,
`graph`, `test`), and C shells for I/O.

## Decision

### 1. The trust boundary is L0 only, and L0 is the only door to the outside

Target TCB of a compiled program: **L0 platform + OS + C compiler + emitter** (the emitter until
translation validation). Everything else is Orin and is proved or checked:

| Layer | Language | Contents | Assurance target |
|---|---|---|---|
| L0 | C, closed list, ≤ 1,000 code lines (contracts and comments excluded; the budget limits trusted code, not its specification) | syscalls, raw memory, formatting floats | every function contract-verified (CBMC/Frama-C); I/O functions validate handle identity and scope |
| L1 core | Orin core dialect | object model, RC/COW, arrays, strings, maps, traps | refinement against the Lean memory machine |
| L2 std | safe Orin | everything else, including all protocols | MIR-verified; contract and class standard; contract quality warnings clean; mutation kill rate gate |

**No escape (binding):**
- every L0 function that touches the outside world takes a **capability handle** parameter;
  there is no L0 I/O entry point without one;
- L0 functions are callable only from modules marked `core = true` in the std manifest (the
  existing `std:fsraw` "prelude only" rule, generalised); user code and third-party packages can
  never call them;
- capability handles are unforgeable (ADR-0021): no literal, no constructor, no copy; derived
  handles only narrow;
- there is no FFI in safe Orin. A future FFI is a declared unsafe boundary that a strict policy
  rejects and OSIG reports as `UNKNOWN` I/O;
- CI gate: OSIG proves every path to an L0 I/O function starts at a grant parameter of `main`;
  a new `PERFORMS_IO` edge outside the allowed modules fails the build (ADR-0029 §4).

### 2. Runtime R3: the object model moves from C to Orin

R3 (spec 19) adds the core dialect: a raw address type, load/store, `size_of` and header access,
restricted to `core` modules. The object model is rewritten in Orin under the class/contract
standard: `retain`, `release`, `make_unique`, allocation, arrays, strings and maps. The C object
model is deleted, so `runtime/` shrinks to nothing and L0 is the only C.

R4: the L1 functions are proved to refine the Lean machine operations (`formal/`). L0 contracts are
verified for all functions, including I/O (with an OS model as an explicit assumption).

Honest limit: the OS kernel, the C compiler and the hardware stay trusted. "No gap in the proof
chain" means: every trusted component is listed in `docs/tcb.md`, is small, and has a written
contract that the next layer's proof assumes.

### 3. The std is built bottom-up, each layer specified before the next

| Std layer | Modules | Notes |
|---|---|---|
| bytes and text | `std:bytes` (byte buffers, slices), `std:utf8` (validated decoding, invariant: always valid UTF-8), `std:fmt` | prerequisite for every protocol |
| collections | `Map`, `Set`, `Deque`, sorted maps, `Graph<T>` | invariants on every structure (sizes, ordering, no duplicates) |
| I/O primitives | `std:fs`, `std:process`, `std:io`, `std:time`, `std:env` | each takes a scoped handle (ADR-0027) |
| network | `std:net`: TCP listener/stream, UDP, DNS, timeouts | new L0 functions `socket/bind/listen/accept/connect/send/recv/poll/close`, each handle-checked; needs the closed-list amendment of spec 19 |
| protocols | `std:http` (HTTP/1.1 parser and server/client), `std:url`, `std:json` (existing, hardened), later TLS via an audited adapter | parsers are pure functions over bytes with contracts (no partial reads accepted, size limits as `@Requires`); the HTTP parser is the first candidate for a verified adapter (ADR-0021 Stage C) |
| applications | `std:mcp` (MCP server/client on `std:json` + stdio/HTTP), `std:html` + JSX | the compiler's own `orin mcp` and `orin lsp` move onto these |

Every std module: contract and class standard, contract-quality warnings clean, `@Test` coverage, a
mutation kill-rate gate, OSIG effect summary in its docs.

**Best known algorithm, fully specified** (project owner, 2026-10-13, binding). Provability and
optimal algorithms do not conflict: B-trees, balanced trees, Swiss tables and DFA decoders all
have published correctness proofs. A std module uses the best known algorithm for its job and
states that algorithm's full invariants. If the contract tooling cannot express an invariant, the
author must either find a formulation that works (for example arena storage with index ids and
iterative helpers) or report the tooling gap so it gets fixed (ADR-0031 A, constraints ADR). A
weaker algorithm is never acceptable for that reason. A simpler version may stay in the tests as
an executable specification, with a differential or property test against the fast one.

A known language gap: there are no equality, ordering or hash constraints on type parameters
(`T extends Eq/Ord/Hash`). This forces key-specialised sets and maps. ADR-0034 adds those
constraints before the std I/O freeze.

### 4. JSX

JSX is **additive syntax** after the language freeze, so it needs its own ADR (ADR-0016 rule).
Direction for that ADR:
- `<div class={c}>{text}</div>` desugars to typed constructor calls of a `JsxFactory` interface;
  no runtime reflection;
- `std:html` renders server-side; text and attribute values are **always escaped by
  construction**; raw HTML exists only as a `SafeHtml` value that cannot be built from a string
  without an explicit, OSIG-visible `trustHtml` call (XSS safety as a type invariant);
- parsing comes with the parser part of the rewrite, so the parser is changed once.

### 5. Order

Constraints: capabilities Stage A changes `platform/` and the I/O std; the compiler rewrite
changes `check/` now and the lowering later; R3 changes lowering and emission.

1. Capabilities Stage A (running).
2. Contract quality and the refusal protocol (running), then the contract gates for the compiler
   **and the std**.
3. Std foundation: `std:bytes`, `std:utf8`, collections, under the new standard (pure Orin, no
   conflicts with the rewrite).
4. `std:net` + `std:http` on blocking sockets (one connection at a time until concurrency;
   ADR-0020 had put HTTP after concurrency, this moves the blocking version forward).
5. R3 core dialect and object model in Orin. It needs the lowering rewrite, so it comes right after
   rewrite step 3 (lower/opt/verify) and is done together with it where possible.
6. `std:mcp`; `orin mcp`/`orin lsp` move onto `std:json` + `std:mcp`.
7. JSX ADR, then parser support and `std:html`.
8. R4 proofs, alongside, as the formal track.

## Consequences

- The proof chain gets one explicit, small trusted base (L0) instead of a large C runtime.
- Every byte in or out passes a handle-checked L0 function, statically and at run time.
- The std becomes large; each module carries contracts and gates, so it costs more per line than
  ordinary code. That is the intended trade.
- Honest limits: protocol correctness (HTTP semantics, TLS) is not proved by memory safety or
  capabilities. Parsers get contracts and tests first; a verified adapter is a separate, later
  claim (ADR-0021 Stage C). Performance of the Orin object model must match the C one (spec 19:
  measure every step).
