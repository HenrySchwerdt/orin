# Allocation census

Status: measurement, re-run 2026-10-16 on main `e23ff6d` (section "Since #71"); previous run 2026-10-15 on main `46b9834` (after the performance wave: #62 unboxing, #64 packed verifier state,
#65 census quick wins, #67 borrow inference, #68 concat reuse, #66, #69 LLVM gate 1). First run 2026-10-14 on `7431756`.
Related: ADR-0038 (performance model, its 2026-10-14 addendum and §8), docs/benchmarks.md.
Reproduce: `./tools/bootstrap.sh && python3 tools/alloc_census.py run && python3 tools/alloc_census.py report`.

Where do the heap allocations and the reference-count operations of Orin programs come from, and which transformation of
ADR-0038 would remove each of them? This report counts them per allocation site on every benchmark, on the HTTP server under
load and on the self-compile, and ranks the transformations by what they would remove. All numbers are counts, which are
deterministic; nothing here is a time measurement (the time and instruction numbers in the summary come from
`tools/bench.py --instructions`, see below).

## Summary: what the wave did, and the ranking now

### Since #71 (re-run 2026-10-16 on main `e23ff6d`)

Re-run after lever 1 (verifier and optimiser data structures) and lever 2 T1 / T3 / T4 landed (T1 drop `makeunique` of a
`Unique` local, T3 scalar stores without the refmask test, T4 load forwarding), plus the std additions (`std:html`, `std:url`,
three new benchmarks: `html`, `html_hand`, `url`). The full run (all 24 workloads, HTTP server under the scripted load
included, no `--no-http` needed) passes the census = total check on every workload. Executed instructions
(`tools/bench.py --instructions`) were not re-measured in this run; the instruction numbers of the earlier tables stand.

Per-workload counts, common workloads only. Every workload not listed is bit-identical to the previous run (allocations,
retains, releases, COW copies): only the self-compile moved, because only the compiler's own code changed. T1 / T3 / T4 act
on instructions, not on allocations, so they cannot show in the census (see lever "per-write checks" below).

| workload | allocs before | allocs after | change | retains before | retains after | releases before | releases after | COW before | COW after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| selfcompile | 17,110,746 | 15,072,609 | -11.9% | 23,693,095 | 21,713,113 | 40,803,841 | 36,785,722 | 1,215,387 | 870,920 |
| the other 18 common workloads | 42,838,108 | 42,838,108 | 0 | 3,955,197 | 3,955,197 | 46,793,305 | 46,793,305 | 1 | 1 |
| **all common workloads** | 59,948,854 | 57,910,717 | -3.4% | 27,648,292 | 25,668,310 | 87,597,146 | 83,579,027 | 1,215,388 | 870,921 |
| new: html, html_hand, url | - | 9,383,384 | | - | 3,207,859 | - | 12,591,243 | - | 0 |
| **all 24 workloads** | | 67,294,101 | | | 28,876,169 | | 96,170,270 | | 870,921 |

Self-compile: allocations -11.9%, retains -8.4%, releases -9.9%, COW copies -28.3%, allocated bytes 3346 MB -> 1328 MB
(-60.3%). The bytes are the clearest effect of lever 1: the `ls` COW copy in `Transfer.set` fell from 427k copies (977 MB) to
56,404 copies; `State.constructor` from 649,374 to 95,424 allocations; `instrUses`' per-call arrays (553,765) became a
`UseBuf` (134,635 buffers, one per `instrUses` entry, 124,310 `list()` slices). What lever 1 did not touch grew with the
source: `Span` 474,312 -> 506,810 and `Token` 474,309 -> 506,807 (the compiler has more lines to lex).

Classification caveat: the class shares of the self-compile are not comparable with the previous run. The RULES are keyed by
function and line, source lines moved, and 4.5% of the self-compile's allocations (previously 0.2%) have no rule now; the three
new workloads have none either, so "unsure" is 10.2% of all allocations (html 63%, html_hand 68%, url 26% of their own).
The counts above, and the per-site counts quoted in the ranking, are exact; only the (a)..(g) split is affected.

### Ranking of the remaining levers (2026-10-16)

Measured on the 24 workloads: 67.3M allocations, 125.0M RC operations (28.9M retains + 96.2M releases). One workload,
bintrees, is 33.4M of the allocations (49.6%) and 33.4M of the RC operations (26.7%) and would dominate any ranking by raw
share, so the shares below are also given without it (33.9M allocations, 91.6M RC operations). Levers are ranked by the
share they remove outside bintrees; bintrees' regions are ranked last for that reason and discussed on their own.

| rank | lever | removes (all workloads) | removes (without bintrees) | evidence (site, from `alloc_census.py top` / `review`) |
|---:|---|---|---|---|
| 1 | string intermediates: decimal text of a number appended to a buffer instead of through a temporary | up to 6.13M allocations (9.1%), 12.7M RC (10.2%); with `html.escape` pieces 7.96M (11.8%) | up to 18.1% of allocations (23.5% with escape) | `std/numbers.usizeToString` std/numbers.or:16: 6,134,690 allocations in 24 workloads, almost all the operand of a concatenation (`"w" + n.toString()`: mapfreq 999,803 = 95% of its allocations, wordfreq 997,837 = 99%, strings 499,995, html 1,592,382 = 37%, html_hand 31%, self-compile 448,876 = 3.0%, of which 384,513 from `cemit/text.u` compiler/cemit/text.or:8); `stdlib/html.escape` stdlib/html.or:84 / :90: 1,830,400 `substring` pieces (2.7% of all allocations) that are appended and dropped; `main.main` bench/strings/main.or:20 `p.substring(4, ..)` 500,000 temporaries. The upper bound: a `toString` whose result is kept (a map key) stays |
| 2 | `Span` / `Token` flattening, and `skipTrivia`'s `Ok(i)` | 680k + 507k = 1.19M allocations (1.8%), 5.4M RC (4.3%); the self-compile alone: 7.9% of its allocations, 9.3% of its RC | same (all in the self-compile) | `diag/diag.span` compiler/diag/diag.or:36: 506,810 allocations, RC on them 1.96M; `diag/diag.spanTo` compiler/diag/diag.or:46: 173,660 allocations, RC 2.96M (together 4.5% of the self-compile's allocations, 8.4% of its RC); `Lexer.emit` compiler/syntax/lexer.or:849: 506,807 `Token` (3.4%, RC 2.0M, stays: a real node), called from `Lexer.punct` :1145 (284,806) and `Lexer.ident` :872 (202,042); `skipTrivia` compiler/syntax/lexer.or:294: 506,622 `Ok(i)` (3.4%, RC 0.5M). Also `Ident` (parser.or:611, 162,005 + 162,005 `Ok(Ident)`) and `HExpr` (check/ops.or:25, 262,890) embed a `Span`. Verified: yes, the share is real, but it is the self-compile only, and the RC (8.4%) is worth more than the allocations (4.5%) |
| 3 | escape analysis / scalar replacement (c) | 1.27M allocations (1.9%), 1.27M RC (1.0%) | 1.27M of 33.9M (3.7%) | selfcompile 6.7% of allocations / 1.7% of RC: `BlockSink` rewrite.or:10-12 (111,473 x 3 allocations), `State` verify/state.or:267 (95,424), `RewritePlan` rewrite.or:87 (94,799), `Transfer` rules.or:125 (74,516), `Transfer.call` `[]` rules.or:520 (56,801), `runBlock` verify.or:131 (92,432), `Cx` calls.or:151..162; `appends` 100% (200,021 `[i]` / `[i, i]` at bench/appends/main.or:49, :55); streams_parallel 16.8%. The RC share is small: these objects are mostly built, passed and dropped, so the gain is the allocation and its free |
| 4 | per-write checks (`make_unique`, kind, bounds): T2 / T5 / U1 of lever 2 | not an allocation lever: self-compile COW copies 870,920 (641k allocation events, 1.0% of all allocations, 350 MB); the benchmarks it targets allocate nothing (mutres 9, pqueue 9, nbody 9, sieve 2 allocations) | | instruction ratios to C (mutres 10.6x, appends 5.0x, pqueue 4.8x, nbody 3.7x, sieve 3.4x) are the evidence, not the census; the census only shows what is left on the allocation side: `opt/analysis.ancestors` compiler/opt/analysis.or:520 `anc[d].push(o)`: 179,733 COW copies (21% of all), `Transfer.set` rules.or:260: 56,404, `Transfer.load` :154: 44,922, `mapSet` array/map.or:204-207: 35,248 x 3 + 26,943 x 2, `FnCtx.newLocal` fnctx.or:254: 22,980 |
| 5 | reuse in place (e), not on the candidate list but measured | 1.36M allocations (2.0%), 510 MB (6.8% of bytes) | | `qsort_func` bench/qsort_func/main.or:18 `qs(lo).concat(eq)`: 477,781; sortedmap `splitChild` collections.or:1020-1021: 8,575 x 2; the COW copies of row 4 are the same class |
| 6 | regions for bintrees (f) | 33.4M allocations (49.6%), 33.4M RC (26.7%) | 0 | `main.make` bench/bintrees/main.or:5 (16,842,752) and :6 (16,563,135): 100% of bintrees, which is already at 0.94x C instructions (C backend), so the measured share is large and the benefit for any other workload is nil. Only a program that builds and drops large trees would gain |

Not ranked: **T6**, removing all kind and bounds checks in `orin_array_at` / `orin_array_slot_ptr`, pending the owner's
decision. The coordinator's measurement for it: nbody -53% instructions, pqueue -37%, sieve -18%, qsort_inplace -16%,
mutres -13%. It is an instruction lever that the census cannot see, and larger than rows 1 to 3 on those five benchmarks.

Smaller items seen in the re-run, no lever of their own: `stdlib/task.putBox<int>` stdlib/task.or:62, 1,220,000 allocations
(81% of the tasks benchmark, class (g): box the payload once); `Bytes.constructor` stdlib/bytes.or:43, 588,396 views (28.5% of
http_parse, class (a)); `sliceString` stdlib/http.or:1387, 947,252 header strings (inherent: they are the result).

**Recommendation.** Row 1 next. It is the largest share outside bintrees (up to 9.1% of all allocations, 10.2% of all RC, 18%
of the non-bintrees allocations), it reaches 24 workloads including the self-compile (3.0%), and it needs no new analysis:
an append-decimal primitive in `std/numbers` (`usizeToString` writes the digits straight into the destination buffer) plus
lowering `a + n.toString()` and `${n}` to it, and `html.escape` appending its pieces instead of materialising them. The
`Span` / `Token` flattening (row 2) is the better second step: its RC share in the self-compile (8.4%) is higher than its
allocation share, but it is a layout change across the lexer, parser and checker and touches only the compiler. Row 4 stays
the standing instruction-level work (T5, T2, U1 as already planned) and T6 waits for the owner. Regions for bintrees: not
before a program needs them.

### Before / after the performance wave

Census counts, all workloads (the new run adds parallel_collatz, streams and streams_parallel: 74k allocations and 0.15M
RC operations, too few to change the comparison):

| | 2026-10-14 (`7431756`) | 2026-10-15 (`46b9834`) | change |
|---|---:|---:|---:|
| allocations | 85.7M | 59.9M | -30% |
| retains | 393.3M | 27.6M | -93% |
| releases | 479.1M | 87.5M | -82% |
| COW copies | 3.22M | 1.22M | -62% |
| self-compile: allocations / retains | 24.8M / 353.8M | 17.1M / 23.7M | -31% / -93% |
| self-compile: executed instructions (valgrind) | 38.97G | 23.85G | -38.8% |

Executed instructions of the Orin binaries (valgrind; the regression metric, reliable on a shared machine; wall times of
the same runs were too noisy to quote), ratio to the C version of the benchmark, C backend / LLVM backend:

| benchmark | before C / LLVM | after C / LLVM | Orin (C backend) change |
|---|---:|---:|---:|
| pqueue | 6.37 / 5.70 | 4.82 / 4.40 | -24.3% |
| qsort_inplace | 3.58 / 2.99 | 2.80 / 2.39 | -21.8% |
| mapfreq | 2.82 / 2.95 | 2.29 / 2.21 | -18.7% |
| sortedmap (no C version) | | | -16.0% |
| wordfreq | 1.70 / 1.69 | 1.43 / 1.37 | -15.7% |
| qsort_func | 1.56 / 1.56 | 1.35 / 1.36 | -13.0% |
| strings | 1.91 / 1.97 | 1.68 / 1.61 | -12.1% |
| http_parse (no C version) | | | -9.7% (LLVM -22.4%) |
| mutres | 11.63 / 9.03 | 10.60 / 7.90 | -8.8% |
| bintrees | 0.99 / 1.03 | 0.94 / 0.94 | -4.7% |
| fib | 1.01 / 1.51 | 1.01 / 0.78 | 0 (LLVM -48%) |
| appends | 4.97 / 5.02 | 4.97 / 5.01 | 0 |
| nbody | 3.68 / 3.07 | 3.68 / 3.14 | 0 |
| sieve | 3.44 / 2.57 | 3.44 / 2.62 | 0 |
| bytesstr | 2.84 / 2.37 | 2.84 / 2.37 | 0 |

LLVM is now at or below the C backend on 13 of 15 instruction rows (appends +0.8%, qsort_func +0.5%; bintrees at par).
What did not move are the benchmarks that allocate almost nothing: their cost is the code around field and element
access, which no census class covers (lever 2 below).

### Ranking of the remaining levers (2026-10-15, superseded by the ranking above)

18.0% of the self-compile's allocations are still (a), but the RC traffic that made (a) and (d) first is gone (retains
-93%). What is left, ranked by expected gain per unit of work:

| rank | lever | class | evidence | what removes it |
|---:|---|---|---|---|
| 1 | verifier and optimiser data structures | (g), with (c)/(e) parts | 27.0% of the self-compile's allocations and 14.2% of its RC are (g), plus 12.6% (c) and 7.2% (e), mostly in `compiler/verify` and `compiler/opt/analysis`; one site alone, the `ls` COW copy in `Transfer.set`, copies 977 MB (427k times) | a per-Fixpoint scratch `ls` filled by `outOf` instead of sharing `ins[b].ls` with the Transfer; one reusable Transfer per Fixpoint; `State.join` in place into the dying `ins[s]`; `instrUses` / `termUses` / `lo` as visitors (553k + 340k arrays); one `successors`; the receiver dup around `callOwned` (class d, 119k record copies). No new analysis; library-level changes inside the compiler |
| 2 | field and element access code | outside the census | instruction ratios to C that the wave did not move: mutres 10.6x, appends 5.0x, pqueue 4.8x, nbody 3.7x, sieve 3.4x | per field write a `make_unique` check plus `struct_get` / `struct_replace` and a reload of the same field (mutres `Reader.next`); per element read a bounds-checked `orin_array_at` and `s2f` even when the same element was read on the line before (nbody). Needs MIR CSE of loads and uniqueness checks within a block, bounds-check hoisting in counted loops, and unique-receiver propagation through in/out methods |
| 3 | escape analysis / scalar replacement | (c) | mean 11.4% of allocations, 9.5% of RC per workload; appends 100%, streams_parallel 16.8%, the verifier's `Transfer` / `State` objects | the ADR-0038 step as planned; overlaps with lever 1 for the verifier |
| 4 | unboxing beyond scalar-only immutable values | (a) | http_server 40.5%, http_parse 37.1%, self-compile 18.0% | flatten `Span` (3 scalars) into `Token` and AST records; `Result`/`Option` with a reference payload returned and matched at once; `Ok(i)` of `skipTrivia` |
| 5 | reuse in place | (e) | 24.1% of all bytes (1.65 GB), sortedmap 20.3% of allocations | join into the dying in-state; field and element take/put in `opt/inplace.or` for `Scope`, `Map.set`, `Locals` |
| 6 | regions / freeze | (f) | 55.7% of raw allocations, but one workload (bintrees), which is already at 0.94x C instructions | regions as planned; low priority until a real program needs it |
| 7 | packed arrays | (b) | 372 MB of buffer bytes, bytesstr and sieve | as planned |
| 8 | LLVM gates 2 + 3 | process | gate 1 (instruction parity) is met | LLVM fixed point of the self-compile and a pinned toolchain; no runtime gain, required for LLVM as the release default |

**Recommendation.** Lever 1 first. It is the cheapest work (no new compiler analysis), it shortens every build, and the
self-compile is the largest workload measured. Lever 2 is the biggest gap to C in user programs and the next real
compiler work, ahead of (c), because the benchmarks it affects allocate nothing. The verifier cost on long fused
functions (open item from the fusion work) is part of lever 1.

Classification note: the RULES were revised for this run. The sites of the verifier, the optimiser and the std changed
with the wave, and the first report left 15.6% of allocations (53.6% of the self-compile) unsure. The revised rules
cover the top ~50 sites one by one and the front end, lowering and optimiser by shape (AST / HIR / MIR nodes are `-`,
field in/out COW copies are (e)); unsure is now 0.1%.

### Previous ranking (2026-10-14, before the wave)

(a) unboxing (24.7% of allocations, 76.7% of RC: mostly the verifier's `LState` records), then (d) borrow (85% of the HTTP
server's RC), (c), (e), (g), (f), (b). (a), (d), (e) and the quick wins of (g) were done in the wave; the verifier's
`LState` became a packed `int` (#64) rather than an unboxed record.

## How it is measured

**Census build (opt-in).** `orin2 compile --stats-sites prog.or -o prog.c` emits the normal C plus, before every MIR
instruction and terminator, `ORIN_SITE(n, orin_site_caller);`, where `n` is the site id (MIR function, block, instruction;
the table `orin_site_names` at the end of the file gives each site's function, position, source span and MIR text) and
`orin_site_caller` is a local every function sets on entry to the call site that entered it. Linked with a runtime built
with `-DORIN_SITE_STATS`, every object records the site that allocated it, and `ORIN_STATS=sites` writes per site:

- objects allocated there, by runtime kind (string, scalar array, reference array, struct with its last tag / slot count /
  reference mask), their bytes (object plus initial buffer, in the layout of a normal build), buffer growths and frees;
- the retains, releases and COW copies *executed* there (on any object) and those *received* by the objects allocated there;
- the joint counts (executing site, allocating site) of retains / releases / COW copies, and (allocating site, calling site)
  of allocations: one level of calling context, so a site in a small std helper can be traced to its callers;
- for scalar arrays, how many of the freed ones held only values below 256 (candidates for packed `u8` storage).

The compiler change is confined to the census mode: `compiler/cemit/cemit.or` (`emitCSites`, the `site` field of the
emitter context, `siteMark` / `nextSite`, the `orin_site_caller` line and the `#define ORIN_SITE_STATS 1` header line, all
behind `sites`), the new `compiler/cemit/sites.or` (site numbering and the table), `compiler/main.or` (the `--stats-sites`
flag; it refuses `--backend=llvm`), and `compiler/mir/print.or` (`instrStr` / `termStr` exported for the table). The runtime
change is behind `#ifdef ORIN_SITE_STATS`; without it every hook is an empty macro. A census-mode program linked with a
normal runtime, or the reverse, does not link (each side references a symbol only the other defines).

**Normal builds are unchanged.** `tools/alloc_census.py identity BASE NEW` compiles the corpus (tests/run, tests/next/run,
bench, examples and the compiler itself) with the compiler before and after this change, to C and to LLVM IR, and compares the
bytes; and the runtime compiled without the flag produces the same object code as before (`objdump -d` identical). Results in
"Gates" below.

**Workloads.** Every `bench/<name>/main.or`; `examples/http_server.or` serving 40 keep-alive loopback connections of 50
requests each (2,000 requests: `GET /health`, `POST /echo` with a 600-byte body, `GET` of an unknown path, in rotation; one
request in flight at a time, so each arrives in one `recv`; the same kind of traffic as `tools/net_checks.py`); and the
self-compile, `orin2 compile compiler/main.or` (the census binary is the compiler itself built in census mode). Counts are
deterministic except for `tasks`, whose thread scheduling varies the channel traffic by up to about 0.15% between runs. The census binary
reproduces the normal build's `ORIN_STATS=1` counters exactly (checked on the self-compile: allocations, retains, releases,
COW copies identical).

**Classification.** Each allocation site gets an object kind (from the runtime kind, the MIR instruction and its source
text: `Some(..)` / built-ins that return Option, the `{receiver, result}` record that `opt/pairs.or` rebuilds after an in/out
call, record literals, class constructors, closures, ...) and the one ADR-0038 class that would remove it:

| class | transformation | removes |
|---|---|---|
| (a) | unboxing of Option, Result, pairs and small records | the allocation; RC on it |
| (b) | packed arrays (`u8[]` etc. in 1-byte elements) | 7/8 of the buffer bytes (not the allocation) |
| (c) | escape analysis, stack allocation, scalar replacement | the allocation; RC on it |
| (d) | borrow inference | a retain / release pair around a read-only use |
| (e) | reuse in place | the allocation (the memory of a dying unique object is reused) |
| (f) | region or freeze | the per-object free / RC of scope-bound or immutable graphs |
| (g) | algorithm or library change | the allocation; RC on it |
| - | inherent | nothing: real long-lived or shared data |
| ? | unsure | the census cannot decide |

The decisions for the sites that matter were made by reading the MIR (`orin2 mir`) and the source; they are the `RULES` of
`tools/alloc_census.py`, each with its reason, and appear in the tables below. Sites without a rule get the default of their
kind (Option / Result / rebuilt pair: (a); closure: (c); everything else: `?`) and are marked `*`.

**Crediting RC operations.** Each retain / release is credited to at most one class, using the joint counts: all operations
on objects of class (f) or (g); for (a) / (c), all operations on objects without reference fields (strings, scalar arrays,
records of scalars), but for objects *with* reference fields only the release that frees them (unboxing such a record moves
its retains to the fields); and for (d), two operations per retain executed at a *borrow candidate*: a `dup` (or an
`unwrap` that retains) whose value is only read until it is released, where passing it to an owned parameter counts as a read
when the callee only reads that parameter (decided the same way, interprocedurally; flow-insensitive, single definition only).
What no class removes is shown as "RC operations not removed".

<!-- generated by tools/alloc_census.py report: begin -->

## Workloads

Totals of one run each (`ORIN_STATS=sites`; the summary counters of the same run). *bytes*: object plus initial buffer plus buffer growth, in the layout of a normal build. The census column checks that the per-site allocations add up to the runtime's own total.

| workload | allocations | bytes | retains | releases | COW copies | census = total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| selfcompile | 15,072,609 | 1327.7 MB | 21,713,113 | 36,785,722 | 870,920 | yes |
| http_server (2,000 requests) | 97,335 | 16.5 MB | 104,085 | 201,420 | 0 | yes |
| http_parse | 2,025,739 | 209.3 MB | 2,493,288 | 4,519,027 | 0 | yes |
| tasks | 1,480,868 | 61.4 MB | 1,240,213 | 2,721,081 | 0 | yes |
| bintrees | 33,405,901 | 1603.5 MB | 0 | 33,405,901 | 0 | yes |
| sortedmap | 86,604 | 18.9 MB | 25,725 | 112,329 | 0 | yes |
| pqueue | 9 | 6.3 MB | 0 | 9 | 0 | yes |
| mapfreq | 1,050,017 | 47.9 MB | 50,000 | 1,100,017 | 0 | yes |
| wordfreq | 1,006,028 | 42.3 MB | 5,001 | 1,011,029 | 0 | yes |
| strings | 1,500,009 | 87.2 MB | 0 | 1,500,009 | 0 | yes |
| qsort_func | 1,911,127 | 623.1 MB | 1 | 1,911,128 | 0 | yes |
| qsort_inplace | 5 | 16.4 MB | 1 | 6 | 1 | yes |
| appends | 200,021 | 16.3 MB | 0 | 200,021 | 0 | yes |
| mutres | 9 | 612 B | 2 | 11 | 0 | yes |
| bytesstr | 123 | 378.5 MB | 0 | 123 | 0 | yes |
| sieve | 2 | 134.2 MB | 0 | 2 | 0 | yes |
| nbody | 9 | 754 B | 0 | 9 | 0 | yes |
| fib | 1 | 51 B | 0 | 1 | 0 | yes |
| html | 4,338,006 | 811.2 MB | 1,602,400 | 5,940,406 | 0 | yes |
| html_hand | 5,034,406 | 549.5 MB | 1,602,000 | 6,636,406 | 0 | yes |
| parallel_collatz | 8 | 33.6 MB | 1 | 9 | 0 | yes |
| streams | 8 | 134.2 MB | 0 | 8 | 0 | yes |
| streams_parallel | 74,285 | 72.1 MB | 36,880 | 111,165 | 0 | yes |
| url | 10,972 | 1331.5 MB | 3,459 | 14,431 | 0 | yes |
| **all** | **67,294,101** | **7521.5 MB** | **28,876,169** | **96,170,270** | **870,921** |  |

## Ranking by transformation (ADR-0038)

Each allocation site is attributed to the one transformation that would remove it (classes below; reviewed decisions in `RULES` of tools/alloc_census.py, kind defaults otherwise). *Allocations*: objects that would no longer be heap-allocated. *RC ops*: retains + releases that would disappear (crediting rules in the method section; each operation is credited to at most one class). *Raw* sums all workloads, so the self-compile (97% of all RC operations) and bintrees (44% of all allocations) dominate it; *mean* weighs every workload equally (workloads with at least 10,000 allocations, resp. RC operations).

| class | transformation | allocations removed (raw) | share | mean share per workload | RC ops removed (raw) | share | mean share per workload | bytes not allocated |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| (a) | unboxing | 4,148,899 | 6.2% | 10.9% | 9,263,469 | 7.4% | 7.1% | 195.6 MB (2.6%) |
| (b) | packed arrays | 0 | 0.0% | 0.0% | 0 | 0.0% | 0.0% | 1278.5 MB (17.0%) |
| (c) | escape / stack / scalar replacement | 1,268,248 | 1.9% | 8.7% | 1,268,248 | 1.0% | 7.5% | 69.0 MB (0.9%) |
| (d) | borrow | 0 | 0.0% | 0.0% | 6,966,704 | 5.6% | 4.1% | 0 B (0.0%) |
| (e) | reuse in place | 1,358,738 | 2.0% | 4.1% | 0 | 0.0% | 0.0% | 510.0 MB (6.8%) |
| (f) | region or freeze | 33,405,887 | 49.6% | 6.7% | 33,405,887 | 26.7% | 6.7% | 0 B (0.0%) |
| (g) | algorithmic or library | 4,404,004 | 6.5% | 15.9% | 9,902,988 | 7.9% | 14.0% | 535.5 MB (7.1%) |
| - | inherent | 15,837,090 | 23.5% | 42.9% | 0 | 0.0% | 0.0% |  |
| ? | unsure | 6,871,235 | 10.2% | 10.9% | 0 | 0.0% | 0.0% |  |
|  | RC operations not removed by any class |  |  |  | 64,239,143 | 51.4% | 60.6% |  |

*Bytes not allocated*: the bytes of the objects a class removes; for (b) the 7/8 of the buffers of `u8[]` arrays that stay allocated; (f) keeps the bytes (a region still holds them) and removes the per-object frees and RC.

Per workload (share of the workload's allocations / of its RC operations; `-` where the workload has fewer than 1,000 of them):

| workload | (a) | (b) | (c) | (d) | (e) | (f) | (g) | - | ? |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| selfcompile | 22.1% / 14.4% | 0.0% / 0.0% | 6.7% / 1.7% | 0.0% / 11.6% | 4.9% / 0.0% | 0.0% / 0.0% | 16.1% / 9.1% | 45.7% / 0.0% | 4.5% / 0.0% |
| http_server | 40.5% / 12.9% | 0.0% / 0.0% | 4.2% / 1.3% | 0.0% / 4.8% | 4.7% / 0.0% | 0.0% / 0.0% | 2.2% / 0.7% | 48.0% / 0.0% | 0.4% / 0.0% |
| http_parse | 37.1% / 10.7% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 1.6% | 6.0% / 0.0% | 0.0% / 0.0% | 2.9% / 3.3% | 53.9% / 0.0% | 0.0% / 0.0% |
| tasks | 0.0% / 0.0% | 0.0% / 0.0% | 2.7% / 1.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 90.5% / 95.4% | 6.8% / 0.0% | 0.0% / 0.0% |
| bintrees | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 100.0% / 100.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% |
| sortedmap | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 37.3% | 20.3% / 0.0% | 0.0% / 0.0% | 39.6% / 24.9% | 40.1% / 0.0% | 0.0% / 0.0% |
| mapfreq | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 100.0% / 0.0% | 0.0% / 0.0% |
| wordfreq | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 99.7% / 0.0% | 0.3% / 0.0% |
| strings | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 33.3% / 33.3% | 66.7% / 0.0% | 0.0% / 0.0% |
| qsort_func | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 25.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 75.0% / 0.0% | 0.0% / 0.0% |
| appends | 0.0% / 0.0% | 0.0% / 0.0% | 100.0% / 100.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% |
| html | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 36.7% / 0.0% | 63.3% / 0.0% |
| html_hand | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 31.6% / 0.0% | 68.4% / 0.0% |
| streams_parallel | 32.9% / 49.5% | 0.0% / 0.0% | 16.8% / 8.4% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 50.0% / 41.6% | 0.2% / 0.0% | 0.2% / 0.0% |
| url | 31.5% / 19.3% | 0.0% / 0.0% | 0.1% / 0.0% | 0.0% / 6.4% | 0.0% / 0.0% | 0.0% / 0.0% | 3.5% / 2.1% | 38.6% / 0.0% | 26.3% / 0.0% |

## Allocations by object kind

| kind | allocations | share | bytes | RC on these objects | mostly in |
| --- | ---: | ---: | ---: | ---: | --- |
| record / variant | 42,359,197 | 62.9% | 2063.9 MB | 72,464,239 | bintrees, selfcompile, tasks +8 more |
| string | 15,008,002 | 22.3% | 1838.0 MB | 27,229,606 | html_hand, html, selfcompile +21 more |
| array (scalar elements) | 4,173,736 | 6.2% | 2907.6 MB | 9,566,546 | selfcompile, qsort_func, appends +17 more |
| Result | 1,864,227 | 2.8% | 82.0 MB | 5,092,647 | selfcompile, http_server, url |
| class object | 1,200,985 | 1.8% | 69.6 MB | 1,693,743 | http_parse, selfcompile, tasks +8 more |
| COW copy | 641,242 | 1.0% | 350.2 MB | 4,307,024 | selfcompile, qsort_inplace |
| map (internal arrays and entries) | 522,657 | 0.8% | 114.5 MB | 1,107,625 | selfcompile, mapfreq |
| Option | 516,179 | 0.8% | 20.6 MB | 877,675 | selfcompile, http_parse, http_server +1 more |
| closure | 485,454 | 0.7% | 22.5 MB | 525,698 | selfcompile, tasks, streams_parallel +4 more |
| array (reference elements) | 413,790 | 0.6% | 47.7 MB | 2,002,268 | selfcompile, http_parse, http_server +10 more |
| task transfer box (runtime) | 100,343 | 0.1% | 4.5 MB | 100,343 | tasks, streams_parallel |
| interface box | 8,248 | 0.0% | 0.4 MB | 78,984 | selfcompile |
| pair (in/out result rebuilt) | 41 | 0.0% | 2 kB | 41 | http_server, selfcompile |

## Packed arrays (b)

Scalar arrays every freed instance of which held only values below 256. *u8[]*: the array is a `u8[]` by type (the byte APIs of the std); the others are `int[]` / `usize[]` whose values happened to be small: packing them needs a proved range (ADR-0038 §3). *Bytes*: buffer bytes allocated there (8 per element today).

| workload | site | u8[] / bool[] by type | arrays | buffer bytes | saved by 1-byte elements | class of the allocation |
| --- | --- | --- | ---: | ---: | ---: | --- |
| url | `stdlib/bytes.ByteBuilder.constructor` stdlib/bytes.or:288 `l1 = arraynew val []` | yes | 2,115 | 1035.7 MB | 906.2 MB | - |
| bytesstr | `stdlib/bytes.bytesFromString` stdlib/bytes.or:254 `l2 = builtin string.toBytes(l0)` | yes | 40 | 335.5 MB | 293.6 MB | - |
| url | `stdlib/bytes.ByteBuilder.appendString` stdlib/bytes.or:415 `l12 = builtin string.toBytes(l1)` | yes | 384 | 187.2 MB | 163.8 MB | (g) |
| sieve | `main.sieve` bench/sieve/main.or:3 `l5 = arraynew val []` | no (range proof) | 1 | 134.2 MB | 117.4 MB | ? |
| http_parse | `stdlib/bytes.ByteBuilder.constructor` stdlib/bytes.or:288 `l1 = arraynew val []` | yes | 17,300 | 78.3 MB | 68.5 MB | - |
| selfcompile | `opt/unique.UniqueSet.step` compiler/opt/unique.or:172 `makeunique l45` | no (range proof) | 14,058 | 30.3 MB | 26.5 MB | ? |
| selfcompile | `opt/unique.uniqueIn` compiler/opt/unique.or:227 `makeunique l12` | no (range proof) | 8,506 | 26.5 MB | 23.2 MB | ? |
| selfcompile | `opt/unique.UniqueSet.step` compiler/opt/unique.or:177 `makeunique l48` | no (range proof) | 10,217 | 23.5 MB | 20.6 MB | ? |
| http_parse | `stdlib/bytes.ByteBuilder.appendString` stdlib/bytes.or:415 `l12 = builtin string.toBytes(l1)` | yes | 6,000 | 17.5 MB | 15.3 MB | (g) |
| selfcompile | `array/map.mapSet<string,check/env.ValEnt>` array/map.or:207 `arraypush l36, true` | yes | 7,971 | 12.4 MB | 10.8 MB | (e) |
| selfcompile | `verify/verify.entryState` compiler/verify/verify.or:71 `l4 = arraynew val []` | no (range proof) | 15,072 | 7.7 MB | 6.7 MB | - |
| selfcompile | `opt/params.liveAfter` compiler/opt/params.or:125 `l11 = arraynew val []` | no (range proof) | 132,080 | 7.0 MB | 6.2 MB | (g) |

## Top 20 allocation sites (all workloads)

Sites are MIR instructions (`function` + block.instruction); the same std function compiled into several workloads is one row. *RC on its objects*: retains + releases the objects allocated there received anywhere. A `*` after the class marks a kind default rather than a reviewed decision.

| # | site | kind | allocations | bytes | RC on its objects | class | workloads | why |
| ---: | --- | --- | ---: | ---: | ---: | --- | --- | --- |
| 1 | `main.make` bench/bintrees/main.or:5 | variant Node(Tree, Tree) | 16,842,752 | 808.5 MB | 16,842,752 | (f) | bintrees | the tree is built, checked and dropped per iteration: a region per iteration (bump allocate, free in one step); the long-lived tree is (f) freeze |
| 2 | `main.make` bench/bintrees/main.or:6 | variant Node(Tree, Tree) | 16,563,135 | 795.0 MB | 16,563,135 | (f) | bintrees | the tree is built, checked and dropped per iteration: a region per iteration (bump allocate, free in one step); the long-lived tree is (f) freeze |
| 3 | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 6,134,690 | 316.2 MB | 12,693,926 | - | html, html_hand, mapfreq +21 more | the result (one allocation per call: the first append copies the immortal "" into a buffer of capacity 9, the other digits are appended in place). The cost is the per-digit loop, not allocations; the second string of `"w" + n.toString()` is counted at the concatenation, class (e) |
| 4 | `stdlib/html.escape` stdlib/html.or:84 | string | 1,830,400 | 64.9 MB | 1,830,400 | ?* | html, html_hand |  |
| 5 | `stdlib/task.putBox<int>` stdlib/task.or:62 | record Box<T> (1 field) | 1,220,000 | 48.8 MB | 3,660,000 | (g) | tasks | a message is boxed in a one-field record, and the runtime moves it into a second box (its own row): two allocations per send; transfer a scalar payload without boxing (runtime API change) |
| 6 | `stdlib/http.sliceString` stdlib/http.or:1387 | string (header name / value / token) | 947,252 | 43.8 MB | 2,801,972 | - | http_parse, http_server | the header names and values of the parsed request are its result; one allocation each since bytesToString |
| 7 | `stdlib/html.trustHtml` stdlib/html.or:188 | record Html (1 fields) | 800,400 | 32.0 MB | 800,400 | ?* | html |  |
| 8 | `main.Row` bench/html/main.or:12 | string | 800,000 | 215.2 MB | 800,000 | ?* | html |  |
| 9 | `main.render` bench/html_hand/main.or:17 | string | 800,000 | 65.2 MB | 800,000 | ?* | html_hand |  |
| 10 | `main.render` bench/html_hand/main.or:18 | string | 800,000 | 72.8 MB | 800,000 | ?* | html_hand |  |
| 11 | `main.render` bench/html_hand/main.or:15 | string | 685,600 | 57.5 MB | 685,600 | ?* | html_hand |  |
| 12 | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 588,396 | 33.0 MB | 793,624 | (a) | http_parse, http_server, url +1 more | a 3-field view created by `Bytes.slice` per chunk / line and dropped after the parse step: unbox the view (pass data/start/len) -- (c) where it does not leave the caller |
| 13 | `std/strings.strSplit` std/strings.or:87 | string (split part) | 516,056 | 22.0 MB | 571,218 | - | strings, selfcompile | the parts are the result |
| 14 | `diag/diag.span` compiler/diag/diag.or:36 | record Span {file, start, end} (3 scalars) | 506,810 | 28.4 MB | 1,962,928 | (a) | selfcompile | 3 scalars stored in every token / AST node. Remains boxed because the unboxing pass rejects a value stored in a slot of a boxed object (Token, Ident, Expr, Stmt, ...): it needs flattening of scalar-only records into their container (a layout change); cf. (a) for values that stay in registers |
| 15 | `syntax/lexer.Lexer.emit` compiler/syntax/lexer.or:849 | record Token {kind, text, span, ...} | 506,807 | 32.4 MB | 1,995,959 | - | selfcompile | the token stream is real data (lives until parsing ends); a region per compiler phase ((f)) would batch-free it |
| 16 | `syntax/lexer.skipTrivia` compiler/syntax/lexer.or:294 | Result | 506,622 | 20.3 MB | 506,622 | (a) | selfcompile | `Ok(i)`: Result<usize, Diag> matched by the caller. Remains boxed because the Err variant carries a Diag reference (slots must be scalar in every variant); returning the position and leaving the error in `this.err` (g) removes it |
| 17 | `main.main` bench/strings/main.or:20 | string (temporary) | 500,000 | 19.4 MB | 500,000 | (g) | strings | `p.substring(4, ..)` only to parse it: parse from an offset |
| 18 | `main.qs` bench/qsort_func/main.or:10 | array<int> | 477,781 | 158.6 MB | 477,781 | - | qsort_func | the partitions of the functional quicksort (inherent to the algorithm) |
| 19 | `main.qs` bench/qsort_func/main.or:11 | array<int> | 477,781 | 38.3 MB | 477,781 | - | qsort_func | the partitions of the functional quicksort (inherent to the algorithm) |
| 20 | `main.qs` bench/qsort_func/main.or:12 | array<int> | 477,781 | 156.1 MB | 477,781 | - | qsort_func | the partitions of the functional quicksort (inherent to the algorithm) |

## Top 5 allocation sites per workload

| workload | site | kind | allocations | share | class |
| --- | --- | --- | ---: | ---: | --- |
| selfcompile | `diag/diag.span` compiler/diag/diag.or:36 | record Span {file, start, end} (3 scalars) | 506,810 | 3.4% | (a) |
| selfcompile | `syntax/lexer.Lexer.emit` compiler/syntax/lexer.or:849 | record Token {kind, text, span, ...} | 506,807 | 3.4% | - |
| selfcompile | `syntax/lexer.skipTrivia` compiler/syntax/lexer.or:294 | Result | 506,622 | 3.4% | (a) |
| selfcompile | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 448,876 | 3.0% | - |
| selfcompile | `syntax/lexer.Lexer.punct` compiler/syntax/lexer.or:1145 | string (punctuation token text) | 284,806 | 1.9% | (g) |
| http_server | `stdlib/http.sliceString` stdlib/http.or:1387 | string (header name / value / token) | 17,336 | 17.8% | - |
| http_server | `stdlib/http.Headers.get` stdlib/http.or:635 | Option | 9,334 | 9.6% | (a) |
| http_server | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 8,080 | 8.3% | (a) |
| http_server | `stdlib/http.Headers.constructor` stdlib/http.or:572 | class object Headers | 8,000 | 8.2% | - |
| http_server | `stdlib/net.recv` stdlib/net.or:347 | Result<u8[], int> + array<u8> | 4,040 | 4.2% | - |
| http_parse | `stdlib/http.sliceString` stdlib/http.or:1387 | string (header name / value / token) | 929,916 | 45.9% | - |
| http_parse | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 578,161 | 28.5% | (a) |
| http_parse | `stdlib/http.Headers.constructor` stdlib/http.or:572 | class object Headers | 81,202 | 4.0% | - |
| http_parse | `stdlib/http.Headers.get` stdlib/http.or:635 | Option | 57,902 | 2.9% | (a) |
| http_parse | `stdlib/http.MessageParser.feed` stdlib/http.or:1727 | variant Done(z, used) | 40,601 | 2.0% | (a) |
| tasks | `stdlib/task.putBox<int>` stdlib/task.or:62 | record Box<T> (1 field) | 1,220,000 | 82.4% | (g) |
| tasks | `stdlib/task.putBox<()=>void>` stdlib/task.or:62 | record (the runtime's transfer box) | 100,023 | 6.8% | (g) |
| tasks | `stdlib/taskcore.Ledger.constructor` stdlib/taskcore.or:122 | class object Ledger (3 fields) | 40,206 | 2.7% | (c) |
| tasks | `stdlib/task.spawn<int>` stdlib/task.or:360 | closure | 40,000 | 2.7% | - |
| tasks | `main.spawnJoin$closure0` bench/tasks/main.or:19 | closure | 40,000 | 2.7% | - |
| bintrees | `main.make` bench/bintrees/main.or:5 | variant Node(Tree, Tree) | 16,842,752 | 50.4% | (f) |
| bintrees | `main.make` bench/bintrees/main.or:6 | variant Node(Tree, Tree) | 16,563,135 | 49.6% | (f) |
| bintrees | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 12 | 0.0% | - |
| bintrees | `main.main` bench/bintrees/main.or:28 | string | 2 | 0.0% | ?* |
| bintrees | `main.main` bench/bintrees/main.or:27 | record (0 fields) | 0 | 0.0% | ?* |
| sortedmap | `stdlib/collections.SortedMap.alloc<int>` stdlib/collections.or:952 | record IntNode {keys, vals, kids} | 8,578 | 9.9% | - |
| sortedmap | `stdlib/collections.SortedMap.release<int>` stdlib/collections.or:958 | IntNode {[], [], []} (a freed arena slot) | 8,578 | 9.9% | (g) |
| sortedmap | `stdlib/collections.SortedMap.release<int>` stdlib/collections.or:958 | IntNode {[], [], []} (a freed arena slot) | 8,578 | 9.9% | (g) |
| sortedmap | `stdlib/collections.SortedMap.release<int>` stdlib/collections.or:958 | IntNode {[], [], []} (a freed arena slot) | 8,578 | 9.9% | (g) |
| sortedmap | `stdlib/collections.SortedMap.release<int>` stdlib/collections.or:958 | IntNode {[], [], []} (a freed arena slot) | 8,578 | 9.9% | (g) |
| mapfreq | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 999,803 | 95.2% | - |
| mapfreq | `array/map.mapEntries<string,int>` array/map.or:255 | record / class object (table, row, report) | 50,000 | 4.8% | - |
| mapfreq | `main.main` bench/mapfreq/main.or:6 | string | 200 | 0.0% | ?* |
| mapfreq | `array/map.buildTab<string>` array/map.or:114 | array (result of a map / table storage / per-function setup) | 8 | 0.0% | - |
| mapfreq | `array/map.mapNew<string,int>` array/map.or:171 | array (result of a map / table storage / per-function setup) | 1 | 0.0% | - |
| wordfreq | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 997,837 | 99.2% | - |
| wordfreq | `main.main` bench/wordfreq/main.or:47 | record Entry {word, count} | 5,000 | 0.5% | - |
| wordfreq | `main.main` bench/wordfreq/main.or:41 | string | 2,166 | 0.2% | ?* |
| wordfreq | `main.main` bench/wordfreq/main.or:33 | array<ref> | 1,024 | 0.1% | ?* |
| wordfreq | `main.main` bench/wordfreq/main.or:30 | array<ref> | 1 | 0.0% | ?* |
| strings | `std/strings.strSplit` std/strings.or:87 | string (split part) | 500,000 | 33.3% | - |
| strings | `main.main` bench/strings/main.or:20 | string (temporary) | 500,000 | 33.3% | (g) |
| strings | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 499,995 | 33.3% | - |
| strings | `main.build` bench/strings/main.or:6 | string | 10 | 0.0% | ?* |
| strings | `std/strings.strSplit` std/strings.or:76 | array<string> (the parts) | 1 | 0.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:10 | array<int> | 477,781 | 25.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:11 | array<int> | 477,781 | 25.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:12 | array<int> | 477,781 | 25.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:18 | array<int> | 477,781 | 25.0% | (e) |
| qsort_func | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 1 | 0.0% | - |
| appends | `main.main` bench/appends/main.or:49 | array<int> (1-2 elements) | 100,000 | 50.0% | (c) |
| appends | `main.main` bench/appends/main.or:55 | array<int> (1-2 elements) | 100,000 | 50.0% | (c) |
| appends | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 8 | 0.0% | - |
| appends | `main.Buf.constructor` bench/appends/main.or:9 | class object Buf (1 fields) | 1 | 0.0% | ?* |
| appends | `main.Buf.add` bench/appends/main.or:13 | string | 1 | 0.0% | ?* |
| html | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 1,592,382 | 36.7% | - |
| html | `stdlib/html.escape` stdlib/html.or:84 | string | 915,200 | 21.1% | ?* |
| html | `stdlib/html.trustHtml` stdlib/html.or:188 | record Html (1 fields) | 800,400 | 18.5% | ?* |
| html | `main.Row` bench/html/main.or:12 | string | 800,000 | 18.4% | ?* |
| html | `stdlib/html.escape` stdlib/html.or:84 | string | 114,400 | 2.6% | ?* |
| html_hand | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 1,592,382 | 31.6% | - |
| html_hand | `stdlib/html.escape` stdlib/html.or:84 | string | 915,200 | 18.2% | ?* |
| html_hand | `main.render` bench/html_hand/main.or:17 | string | 800,000 | 15.9% | ?* |
| html_hand | `main.render` bench/html_hand/main.or:18 | string | 800,000 | 15.9% | ?* |
| html_hand | `main.render` bench/html_hand/main.or:15 | string | 685,600 | 13.6% | ?* |
| streams_parallel | `stdlib/taskcore.Ranges.constructor` stdlib/taskcore.or:172 | class object Ranges (4 fields) | 12,260 | 16.5% | (c) |
| streams_parallel | `stdlib/task.loadRanges` stdlib/task.or:647 | array<usize> (lo / hi of the workers) | 12,250 | 16.5% | (g) |
| streams_parallel | `stdlib/task.loadRanges` stdlib/task.or:648 | array<usize> (lo / hi of the workers) | 12,250 | 16.5% | (g) |
| streams_parallel | `stdlib/task.inOrder<Option<int>>` stdlib/task.or:762 | Option | 12,210 | 16.4% | (a)* |
| streams_parallel | `stdlib/task.poolWork<Option<int>>` stdlib/task.or:691 | record Done<R> {k, r} | 12,210 | 16.4% | (g) |
| url | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 2,115 | 19.3% | (a) |
| url | `stdlib/bytes.Bytes.toRawString` stdlib/bytes.or:187 | string | 2,115 | 19.3% | ?* |
| url | `stdlib/bytes.ByteBuilder.constructor` stdlib/bytes.or:288 | array<scalar> | 2,115 | 19.3% | - |
| url | `stdlib/bytes.ByteBuilder.constructor` stdlib/bytes.or:287 | class object ByteBuilder (2 fields) | 2,115 | 19.3% | - |
| url | `stdlib/url.decodeRange` stdlib/url.or:122 | Result | 960 | 8.7% | (a)* |

## Top RC sites

Retains at borrow candidates (class d: the retained value is only read before its release, MIR analysis), and the allocation sites whose objects receive the most RC operations.

| workload | retain site | MIR | RC ops removed (2 x retains) |
| --- | --- | --- | ---: |
| selfcompile | `syntax/lexer.Lexer.step` compiler/syntax/lexer.or:550 | `l4 = dup l31` | 984,478 |
| selfcompile | `verify/rules.Transfer.run` compiler/verify/rules.or:172 | `l2 = dup l7` | 869,248 |
| selfcompile | `verify/verify.Fixpoint.run` compiler/verify/verify.or:294 | `l5 = dup l27` | 776,816 |
| selfcompile | `opt/unbox.Unboxing.isRef` compiler/opt/unbox.or:396 | `l4 = dup l7` | 736,088 |
| selfcompile | `syntax/lexer.Lexer.punct` compiler/syntax/lexer.or:1096 | `l2 = dup l10` | 553,586 |
| selfcompile | `syntax/lexer.Lexer.ident` compiler/syntax/lexer.or:860 | `l2 = dup l8` | 391,740 |
| selfcompile | `syntax/parser.Parser.parseIdent` compiler/syntax/parser.or:604 | `l2 = dup l8` | 324,494 |
| selfcompile | `verify/rules.Transfer.instr` compiler/verify/rules.or:819 | `l23 = dup l122` | 262,964 |
| selfcompile | `syntax/parser.Parser.levelHere` compiler/syntax/parser.or:1924 | `l2 = dup l5` | 243,870 |
| selfcompile | `syntax/parser.Parser.parseUnary` compiler/syntax/parser.or:1950 | `l2 = dup l12` | 210,702 |
| selfcompile | `syntax/parser.Parser.parsePrimary` compiler/syntax/parser.or:2060 | `l2 = dup l28` | 208,364 |
| selfcompile | `opt/opt.ParamInference.wants` compiler/opt/opt.or:123 | `l4 = dup l10` | 100,104 |
| selfcompile | `lower/builder.BlockBuilder.finish` compiler/lower/builder.or:167 | `l13 = dup l50` | 88,890 |
| selfcompile | `check/stmt.StmtChecker.block` compiler/check/stmt.or:105 | `l82 = dup l81` | 87,910 |
| selfcompile | `verify/rules.Transfer.term` compiler/verify/rules.or:246 | `l40 = dup l39` | 87,876 |

| workload | allocation site | kind | objects | retains + releases on them | per object | class |
| --- | --- | --- | ---: | ---: | ---: | --- |
| bintrees | `main.make` bench/bintrees/main.or:5 | variant Node(Tree, Tree) | 16,842,752 | 16,842,752 | 1.0 | (f) |
| bintrees | `main.make` bench/bintrees/main.or:6 | variant Node(Tree, Tree) | 16,563,135 | 16,563,135 | 1.0 | (f) |
| html | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 1,592,382 | 4,780,362 | 3.0 | - |
| html_hand | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 1,592,382 | 4,780,362 | 3.0 | - |
| selfcompile | `check/decls.resolveFunc` compiler/check/decls.or:168 | record (AST / HIR / MIR data) | 3,226 | 4,158,456 | 1289.0 | - |
| tasks | `stdlib/task.putBox<int>` stdlib/task.or:62 | record Box<T> (1 field) | 1,220,000 | 3,660,000 | 3.0 | (g) |
| selfcompile | `diag/diag.spanTo` compiler/diag/diag.or:46 | record Span {file, start, end} (3 scalars) | 173,660 | 2,962,006 | 17.1 | (a) |
| selfcompile | `syntax/lexer.Lexer.ident` compiler/syntax/lexer.or:867 | string (identifier text) | 202,042 | 2,849,212 | 14.1 | - |
| http_parse | `stdlib/http.sliceString` stdlib/http.or:1387 | string (header name / value / token) | 929,916 | 2,721,960 | 2.9 | - |
| http_parse | `stdlib/bytes.bytesFromString` stdlib/bytes.or:254 | array<u8> | 5 | 2,291,409 | 458281.8 | - |
| selfcompile | `syntax/lexer.Lexer.emit` compiler/syntax/lexer.or:849 | record Token {kind, text, span, ...} | 506,807 | 1,995,959 | 3.9 | - |
| selfcompile | `loader/sources.Sources.read` compiler/loader/sources.or:61 | Result | 348 | 1,983,080 | 5698.5 | (a) |

## COW copies

| workload | site | copies | allocations there | class |
| --- | --- | ---: | ---: | --- |
| selfcompile | `opt/analysis.ancestors` compiler/opt/analysis.or:520 `arraypush l50, l19` | 179,733 | 179,733 | (e) |
| selfcompile | `verify/rules.Transfer.set` compiler/verify/rules.or:260 `makeunique l6` | 56,404 | 56,404 | (g) |
| selfcompile | `verify/rules.Transfer.load` compiler/verify/rules.or:154 `makeunique l9` | 44,922 | 44,922 | (e) |
| selfcompile | `array/map.mapSet<string,check/fnctx.Bind>` array/map.or:205 `arraypush l33, l32` | 35,248 | 35,248 | (e) |
| selfcompile | `array/map.mapSet<string,check/fnctx.Bind>` array/map.or:206 `arraypush l35, l34` | 35,248 | 35,248 | (e) |
| selfcompile | `array/map.mapSet<string,check/fnctx.Bind>` array/map.or:207 `arraypush l36, true` | 35,248 | 35,248 | (e) |
| selfcompile | `array/map.mapSet<string,check/fnctx.Bind>` array/map.or:204 `makeunique l3` | 26,943 | 26,943 | (e) |
| selfcompile | `array/map.mapSet<string,check/fnctx.Bind>` array/map.or:204 `makeunique l31` | 26,943 | 26,943 | (e) |
| selfcompile | `check/fnctx.FnCtx.newLocal` compiler/check/fnctx.or:254 `arraypush l12, l11` | 22,980 | 22,980 | (e) |
| selfcompile | `check/fnctx.Scope.bind` compiler/check/fnctx.or:72 `makeunique l3` | 22,688 | 22,688 | (e) |

<!-- generated: end -->

## Quick wins of class (g): library changes, no compiler work

Measured on the workloads above; each is a change to one std function (or the runtime API under it).

| # | where | what allocates | measured | fix |
|---:|---|---|---:|---|
| 1 | `MessageParser.feed`, `bodyBytes` (stdlib/http.or:1647, 2607) via `Bytes.toArray` (stdlib/bytes.or:165) | `chunk.slice(w, we).toArray()` copies every window of the input into a fresh `u8[]` so that `doName` / `doValue` / ... can index it; `bodyBytes` copies each body part again and then pushes it byte by byte | http_parse: 459,251 allocations (11.8%), 241 MB (46% of its bytes); http_server: 4,000 | let the line scanners read the view's array and offset directly (a package-internal accessor of `Bytes`), and build the body with one bulk copy |
| 2 | `putBox` (stdlib/task.or:59) and `orin_rt_transfer_put` | every message is boxed in a one-field `Box<T>` record, which the runtime moves into a second box for the receiver | tasks: 2,560,025 allocations (39%) | transfer a scalar payload without a box (a token that carries the scalar), keep the box for reference payloads |
| 3 | `ByteBuilder.appendBytes` (stdlib/bytes.or:366) | per byte, `b.length()` and `b.at(i)`: two calls with a retain and a release of `b` each (no allocation) | http_server: 1.64M RC operations, 75% of all its RC; http_parse: 3.66M | one bulk append of the view's range (`orin_array_extend` of a slice, or a built-in that appends `data[start, start + len)`) |
| 4 | `ByteBuilder.appendString` (stdlib/bytes.or:376) | `this.data.concat(stringToBytes(s))` builds a temporary `u8[]` per appended string | http_server: 16,000 (11.1%); http_parse: 48,000 | append the string's bytes in place (a built-in `appendStringBytes(u8[], string)`, the inverse of `bytesToString`) |
| 5 | `MessageParser.doValue` / `doName` / `doMethod` / `doTarget` (stdlib/http.or:2169-2182) | `tok` / `this.acc + sliceString(..)` re-concatenate a token that spans two windows | http_parse: 72,700 | append the second piece to the accumulator in place (`this.acc += ..`, then take it) |
| 6 | `fieldsText` (stdlib/http.or:2834) | the header lines as a `string[]` of 4 parts per field, then `join("")` | 6,000 / 2,000 arrays plus their growth and the joined string | append each part to one string (or straight to the response's `ByteBuilder`) |
| 7 | `emptyBytes()` (stdlib/bytes.or:214) | `new Bytes([], 0, 0)`: an empty array and a view per call | http_parse: 17,300 + views; http_server: 3,373 | `bodyBytes` / the server can represent "no body" without building it |
| 8 | `toLowerAscii` (stdlib/http.or:138), `Bytes.toHex` (stdlib/bytes.or:177), the JSON string escaper (stdlib/json.or:140) | one `string[]` element per input byte (the 1-byte strings are shared immortals, so no allocation per byte, but 8 bytes per byte of array, its growths and a `join`) | not exercised by these workloads | `out += ..` on one string (amortised in place since fix 1 of docs/benchmarks.md) |

Not library code but equally cheap, found on the way (other owners):

- `opt/analysis.instrUses` / `lo` / `los` / `termUses` (compiler/opt/analysis.or) return a fresh `usize[]` per operand
  and per instruction only to be iterated: 1.81M allocations, 7.3% of the self-compile. A visitor or a caller-owned buffer.
  `ancestors` (same file) allocates 654,294 worklists.
- `Lexer.punct` (compiler/syntax/lexer.or:761): `src.substring(..)` for every punctuation token (230,943); the text is one
  of a fixed set of literals.
- `cemit.genFunction` builds every C line as its own string (125,739 + 91,572) before joining them.
- The benchmark `strings` parses `p.substring(4, p.length)` (500,000 temporary strings); a `parseInt` from an offset would
  avoid them.
- Class (e), but a plain compiler fix: `Lowerer.emit` calls `this.b.emit(i, this.sp)` as `dup this.b; call; setfield`,
  so the builder has two owners during the call and **every emitted instruction copies the `BlockBuilder` and both of
  its arrays** (123,440 copies each, 46 MB allocated; quadratic in the block length). The take / put rewrite of
  `opt/inplace.or` does not fire on this call; the census cannot say why (a second field of `this` in the arguments is the
  visible difference to the calls it does rewrite).

## Gates

- **Normal builds unchanged.** `alloc_census.py identity` with the compiler of the merge commit before this change (`de8d2b1`)
  and the new one: 414 programs (tests/run, tests/next/run, bench, examples, the compiler itself) x {C, LLVM IR} = 828
  outputs, all byte-identical, all compiled. The runtime compiled without `ORIN_SITE_STATS` has the same object code as
  before (`objdump -d` of `orin_runtime.o` identical); `runtime/tests/runtime_test.c` passes under ASan + UBSan.
- **Census mode** builds and runs on all 16 benchmarks, the HTTP server and the self-compile; in every workload the
  per-site allocations add up to the runtime's total, and the census binary of the self-compile reproduces the normal
  build's `ORIN_STATS=1` counters. Census runtime under ASan + UBSan (tasks, sortedmap, http_parse) and ThreadSanitizer
  (tasks): no reports.
- **Tests**: `tools/run_tests.py --suite all` with the new `orin2`: 832 passed, 0 failed (run 80, errors 61, next/run 309, next/errors 382).
- **Bootstrap**: fixed point, `stage2.c == stage3.c` (9,355,865 bytes); the default conformance suite with that `orin2`:
  141 passed, 0 failed.

## Limits

- **Attribution is per site, not per call path.** A site in a small std helper (`Bytes.constructor`, `usizeToString`)
  is one row for all its callers; the census keeps one level of calling context (`top --callers N` prints it), which is
  how the rows above were traced, but the tables do not split by caller.
- **The classes are decisions, not proofs.** Each reviewed site has its reason in `RULES`; whether the transformation
  applies at a given site still has to be shown by the pass that implements it (escape, uniqueness, purity). Where the
  census could not decide, the site is `?`, and the kind defaults (Option / Result / pair: (a), closure: (c)) are marked.
- **(d) is a syntactic, flow-insensitive estimate**: two RC operations per retain whose value is only read before its
  release (interprocedurally through owned parameters the callee only reads). It misses borrows across loops and those
  that need a value to be stored temporarily, and does not check that the matching release is on every path.
- **Unboxing records with reference fields** is credited only with the release that frees the box: copying such a value
  retains its fields instead. LState, Span, Ring and the Options of scalars have no reference fields; `Bytes` has one.
- **Bytes** are object plus initial buffer plus growth in the normal-build layout; malloc overhead is not counted. For
  (f) no bytes are counted as saved (a region still holds them).
- **Workload choice.** The raw sums are dominated by the self-compile (97% of all RC operations) and bintrees (39% of all
  allocations); the mean columns weigh the 13 workloads with at least 10,000 allocations (14 with at least 10,000 RC operations) equally.
  The HTTP server runs 2,000 sequential keep-alive requests on loopback; concurrency, larger bodies or JSON payloads are
  not covered (there is no JSON endpoint in the example).
- **Census mode is C backend only** (`--stats-sites` refuses `--backend=llvm`): the LLVM backend hard-codes the object
  layout, which the census extends by 8 bytes. Counts do not depend on the backend.
