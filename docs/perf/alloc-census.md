# Allocation census

Status: measurement, 2026-10-14. Related: ADR-0038 (performance model, its 2026-10-14 addendum and §8), docs/benchmarks.md.
Reproduce: `./tools/bootstrap.sh && python3 tools/alloc_census.py run && python3 tools/alloc_census.py report`.

Where do the heap allocations and the reference-count operations of Orin programs come from, and which transformation of
ADR-0038 would remove each of them? This report counts them per allocation site on every benchmark, on the HTTP server under
load and on the self-compile, and ranks the transformations by what they would remove. All numbers are counts, which are
deterministic; nothing here is a time measurement.

## Summary: the ranking for the performance wave

18 workloads, 85.7M allocations, 393M retains, 479M releases, 3.2M COW copies (tables below). Ranked by what each
transformation would remove (raw = all workloads summed; mean = every workload weighted equally):

| rank | class | allocations removed: raw / mean per workload | RC ops removed: raw / mean per workload | where it comes from |
|---:|---|---:|---:|---|
| 1 | (a) unboxing | 24.7% / 37.4% | 76.7% / 26.7% | `LState {k, src}` records of the ownership verifier (4.1M objects that receive 647M RC operations, 74% of all RC operations measured, through the COW copies of `ls: LState[]` and the dups around `joinLs`); Option from `pop()`, `get()`, `Map.get`, `recv()`; `Result` in the parser and lexer; the `{receiver, result}` pairs that `opt/pairs.or` rebuilds after an in/out call (3.0M); the `Bytes` view; `Span` |
| 2 | (d) borrow | - / - | 8.1% / 20.7% | methods whose `this` is an owned parameter they only read (`Bytes.length` / `at`, `isDone`, `isFailed`, `canPop`, `canPush`, `Reader.cur`, `SortedMap.get` ...): the caller dups the receiver, the callee releases it. 85% of the HTTP server's RC operations, 59% of http_parse's, all of mutres's |
| 3 | (c) escape / scalar replacement | 6.4% / 12.7% | 1.8% / 11.6% | the channel `Ring` of std:task (40% of tasks' allocations, 60% of its RC), the verifier's per-block context `Cx` and its empty `errs` / `warns`, `let xs: u8[] = []` per `feed`, `[i]` passed to `concat` |
| 4 | (e) reuse in place | 5.7% / 12.3% | - | `"w" + n.toString()` (the number string dies right there), `qs(lo).concat(eq).concat(qs(hi))`, `joinState` replacing a dying in-state, `MessageParser.reset`'s five new arrays per message, and a copy of the lowerer's `BlockBuilder` and both its arrays for **every** emitted instruction (quadratic; see the COW table) |
| 5 | (g) algorithm / library | 8.0% / 8.1% | 1.4% / 3.4% | quick wins below: `Bytes.toArray` copies in the HTTP parser, the double box per task message, temporary `u8[]` per `ByteBuilder.appendString`, fresh `usize[]` per operand in the optimiser's `instrUses` |
| 6 | (f) region / freeze | 39.0% / 7.7% | 3.8% / 7.1% | one workload: bintrees (a tree built, checked and dropped per iteration). Compiler phases (tokens, AST, HIR: classed `-` here) are the next candidates once regions exist |
| 7 | (b) packed arrays | bytes only | - | 384 MB of buffer bytes (4.5% of all bytes): `u8[]` from `stringToBytes`, `ByteBuilder`, the parser's body bytes; another 117 MB in sieve's `int[]` of 0/1 flags needs a range proof |

What stays: 9.7% of the allocations are real data (`-`: tokens, AST, header names and values, results) and 6.5% are
not decided (`?`, mostly the long tail of the self-compile and a few COW copies whose second owner the census cannot name);
8.2% of the RC operations are not removed by any class (mean 30.4%; the census credits only what it can show).

**Recommendation.** Start with (a): it is first in three of the four columns (raw allocations go to (f), which is one
benchmark), its biggest single item is one record type of the verifier, and its cheapest part needs no new analysis: in
the cases inspected (pqueue, sortedmap, the HTTP parser, the compiler's parser) the rebuilt in/out pairs (3.0M in all) are pairs that
`opt/pairs.or` leaves in place because the call's result is moved to another local and matched from there (`l24 = struct
tag0 {l59, l63}; l4 = move l24; l25 = getfield l4.0; ...`), and Option / Result of scalars returned and matched at once
are the textbook case. Then (d):
inferring that a method only reads its owned `this` removes most of the RC traffic of the HTTP workloads. (c) and (e)
follow; (f) matters for allocation-heavy tree code, (b) for byte-heavy I/O.

### After borrow inference (class (d), `compiler/opt/borrow.or`)

`ORIN_STATS=1` counters of the normal build, before (main) and after; allocations are unchanged except for the optimiser's own
(+0.25% in the self-compile). The census above was taken before this change.

| workload | retains before | after | releases before | after |
|---|---:|---:|---:|---:|
| mutres | 20,000,002 | 2 | 20,000,015 | 15 |
| http_parse | 8,374,350 | 2,934,040 | 10,951,367 | 5,511,057 |
| sortedmap | 970,321 | 498,021 | 2,878,596 | 2,406,296 |
| pqueue | 800,003 | 600,000 | 4,400,015 | 4,200,012 |
| mapfreq, wordfreq | unchanged | | unchanged | |
| self-compile | 358,945,500 | 342,271,731 | 388,149,213 | 371,548,740 |

The inference is by read-only *copies* of a parameter: the lowering writes `d = dup p` for every use of a parameter in a
body, and that retain made the parameter owned. The remaining dup/release pairs of the census's (d) rows are copies of
borrowed projections (`getfield` results held across a call that may release the owner), which need an invalidation analysis
and are not covered; and methods that mutate `this` (in/out receivers) keep it owned.

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
| selfcompile | 24,840,827 | 4125.2 MB | 353,841,685 | 378,682,512 | 3,223,780 | yes |
| http_server (2,000 requests) | 144,660 | 29.1 MB | 1,026,208 | 1,170,868 | 0 | yes |
| http_parse | 3,882,460 | 524.6 MB | 9,010,898 | 12,893,358 | 0 | yes |
| tasks | 6,502,724 | 345.0 MB | 7,626,197 | 14,128,921 | 0 | yes |
| bintrees | 33,405,905 | 1603.5 MB | 0 | 33,405,905 | 0 | yes |
| sortedmap | 1,908,275 | 96.2 MB | 970,321 | 2,878,596 | 0 | yes |
| pqueue | 3,600,012 | 159.9 MB | 800,003 | 4,400,015 | 0 | yes |
| mapfreq | 2,999,821 | 135.5 MB | 50,000 | 3,049,821 | 0 | yes |
| wordfreq | 2,003,865 | 90.0 MB | 5,001 | 2,008,866 | 0 | yes |
| strings | 2,500,003 | 130.5 MB | 0 | 2,500,003 | 0 | yes |
| qsort_func | 2,388,909 | 699.2 MB | 1 | 2,388,910 | 0 | yes |
| qsort_inplace | 1,355,402 | 70.6 MB | 1 | 1,355,403 | 1 | yes |
| appends | 200,027 | 16.3 MB | 0 | 200,027 | 0 | yes |
| mutres | 13 | 794 B | 20,000,002 | 20,000,015 | 0 | yes |
| bytesstr | 125 | 378.5 MB | 40 | 165 | 0 | yes |
| sieve | 3 | 134.2 MB | 0 | 3 | 0 | yes |
| nbody | 13 | 950 B | 0 | 13 | 0 | yes |
| fib | 2 | 108 B | 0 | 2 | 0 | yes |
| **all** | **85,733,046** | **8538.4 MB** | **393,330,357** | **479,063,403** | **3,223,781** |  |

## Ranking by transformation (ADR-0038)

Each allocation site is attributed to the one transformation that would remove it (classes below; reviewed decisions in `RULES` of tools/alloc_census.py, kind defaults otherwise). *Allocations*: objects that would no longer be heap-allocated. *RC ops*: retains + releases that would disappear (crediting rules in the method section; each operation is credited to at most one class). *Raw* sums all workloads, so the self-compile (97% of all RC operations) and bintrees (44% of all allocations) dominate it; *mean* weighs every workload equally (workloads with at least 10,000 allocations, resp. RC operations).

| class | transformation | allocations removed (raw) | share | mean share per workload | RC ops removed (raw) | share | mean share per workload | bytes not allocated |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| (a) | unboxing | 21,209,713 | 24.7% | 37.4% | 669,029,929 | 76.7% | 26.7% | 941.9 MB (11.0%) |
| (b) | packed arrays | 0 | 0.0% | 0.0% | 0 | 0.0% | 0.0% | 383.5 MB (4.5%) |
| (c) | escape / stack / scalar replacement | 5,461,477 | 6.4% | 12.7% | 15,833,433 | 1.8% | 11.6% | 356.4 MB (4.2%) |
| (d) | borrow | 0 | 0.0% | 0.0% | 70,469,666 | 8.1% | 20.7% | 0 B (0.0%) |
| (e) | reuse in place | 4,927,075 | 5.7% | 12.3% | 0 | 0.0% | 0.0% | 1656.7 MB (19.4%) |
| (f) | region or freeze | 33,405,887 | 39.0% | 7.7% | 33,405,887 | 3.8% | 7.1% | 0 B (0.0%) |
| (g) | algorithmic or library | 6,699,738 | 7.8% | 8.0% | 9,905,952 | 1.1% | 3.4% | 578.3 MB (6.8%) |
| - | inherent | 8,446,228 | 9.9% | 19.7% | 0 | 0.0% | 0.0% |  |
| ? | unsure | 5,582,928 | 6.5% | 2.2% | 0 | 0.0% | 0.0% |  |
|  | RC operations not removed by any class |  |  |  | 73,748,893 | 8.5% | 30.4% |  |

*Bytes not allocated*: the bytes of the objects a class removes; for (b) the 7/8 of the buffers of `u8[]` arrays that stay allocated; (f) keeps the bytes (a region still holds them) and removes the per-object frees and RC.

Per workload (share of the workload's allocations / of its RC operations; `-` where the workload has fewer than 1,000 of them):

| workload | (a) | (b) | (c) | (d) | (e) | (f) | (g) | - | ? |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| selfcompile | 40.7% / 89.8% | 0.0% / 0.0% | 8.8% / 0.3% | 0.0% / 1.6% | 5.1% / 0.0% | 0.0% / 0.0% | 12.1% / 0.5% | 11.2% / 0.0% | 22.1% / 0.0% |
| http_server | 37.4% / 2.5% | 0.0% / 0.0% | 4.2% / 0.3% | 0.0% / 84.9% | 6.9% / 0.0% | 0.0% / 0.0% | 17.5% / 1.2% | 31.9% / 0.0% | 2.1% / 0.0% |
| http_parse | 40.0% / 7.1% | 0.0% / 0.0% | 11.2% / 2.0% | 0.0% / 58.7% | 5.2% / 0.0% | 0.0% / 0.0% | 15.5% / 3.5% | 28.0% / 0.0% | 0.0% / 0.0% |
| tasks | 18.8% / 5.6% | 0.0% / 0.0% | 40.3% / 59.7% | 0.0% / 11.2% | 0.0% / 0.0% | 0.0% / 0.0% | 39.4% / 22.8% | 1.5% / 0.0% | 0.0% / 0.0% |
| bintrees | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 100.0% / 100.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% |
| sortedmap | 95.5% / 47.3% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 25.9% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 4.5% / 0.0% |
| pqueue | 100.0% / 69.2% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 7.7% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% |
| mapfreq | 33.3% / 32.3% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 33.3% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 33.3% / 0.0% | 0.0% / 0.0% |
| wordfreq | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 49.9% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 50.0% / 0.0% | 0.1% / 0.0% |
| strings | 20.0% / 20.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 20.0% / 0.0% | 0.0% / 0.0% | 20.0% / 20.0% | 40.0% / 0.0% | 0.0% / 0.0% |
| qsort_func | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 40.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 60.0% / 0.0% | 0.0% / 0.0% |
| qsort_inplace | 100.0% / 100.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% |
| appends | 0.0% / 0.0% | 0.0% / 0.0% | 100.0% / 100.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.0% / 0.0% |
| mutres | - / 0.0% | - / 0.0% | - / 0.0% | - / 100.0% | - / 0.0% | - / 0.0% | - / 0.0% | - / 0.0% | - / 0.0% |

## Allocations by object kind

| kind | allocations | share | bytes | RC on these objects | mostly in |
| --- | ---: | ---: | ---: | ---: | --- |
| record / variant | 44,076,234 | 51.4% | 2143.7 MB | 716,896,766 | bintrees, selfcompile, tasks +6 more |
| Option | 9,793,590 | 11.4% | 391.7 MB | 11,024,200 | pqueue, selfcompile, qsort_inplace +6 more |
| string | 8,918,031 | 10.4% | 520.2 MB | 13,975,561 | strings, mapfreq, wordfreq +15 more |
| array (scalar elements) | 7,463,552 | 8.7% | 1838.5 MB | 10,221,276 | selfcompile, qsort_func, http_parse +10 more |
| class object | 3,765,835 | 4.4% | 253.3 MB | 77,107,511 | tasks, http_parse, selfcompile +6 more |
| COW copy | 3,054,379 | 3.6% | 1775.7 MB | 19,103,953 | selfcompile, qsort_inplace |
| pair (in/out result rebuilt) | 3,035,167 | 3.5% | 145.7 MB | 4,018,505 | selfcompile, pqueue, http_parse +3 more |
| array (reference elements) | 2,523,873 | 2.9% | 1265.5 MB | 11,331,379 | selfcompile, http_parse, http_server +5 more |
| Result | 1,434,713 | 1.7% | 64.3 MB | 3,974,347 | selfcompile, http_server |
| task transfer box (runtime) | 1,320,025 | 1.5% | 53.3 MB | 3,720,031 | tasks |
| map (internal arrays and entries) | 242,764 | 0.3% | 81.7 MB | 677,360 | selfcompile, mapfreq |
| closure | 99,490 | 0.1% | 4.6 MB | 139,494 | tasks, selfcompile, http_server |
| interface box | 5,393 | 0.0% | 0.3 MB | 203,377 | selfcompile |

## Packed arrays (b)

Scalar arrays every freed instance of which held only values below 256. *u8[]*: the array is a `u8[]` by type (the byte APIs of the std); the others are `int[]` / `usize[]` whose values happened to be small: packing them needs a proved range (ADR-0038 §3). *Bytes*: buffer bytes allocated there (8 per element today).

| workload | site | u8[] / bool[] by type | arrays | buffer bytes | saved by 1-byte elements | class of the allocation |
| --- | --- | --- | ---: | ---: | ---: | --- |
| bytesstr | `stdlib/bytes.bytesFromString` stdlib/bytes.or:239 `l2 = builtin string.toBytes(l0)` | yes | 40 | 335.5 MB | 293.6 MB | - |
| http_parse | `stdlib/bytes.Bytes.toArray` stdlib/bytes.or:165 `l7 = builtin arr.slice(l2, l3, l6)` | yes | 459,251 | 219.2 MB | 191.8 MB | (g) |
| sieve | `main.sieve` bench/sieve/main.or:3 `l5 = arraynew val []` | no (range proof) | 1 | 134.2 MB | 117.4 MB | ? |
| http_parse | `stdlib/http.MessageParser.bodyBytes` stdlib/http.or:2604 `l16 = arraynew val []` | yes | 11,300 | 40.9 MB | 35.8 MB | - |
| http_parse | `stdlib/bytes.ByteBuilder.constructor` stdlib/bytes.or:270 `l1 = arraynew val []` | yes | 6,000 | 37.4 MB | 32.8 MB | - |
| http_parse | `stdlib/bytes.ByteBuilder.appendString` stdlib/bytes.or:376 `l4 = builtin string.toBytes(l1)` | yes | 48,000 | 18.8 MB | 16.5 MB | (g) |
| selfcompile | `array/map.mapSet<string,check/env.ValEnt>` array/map.or:207 `arraypush l36, true` | yes | 6,567 | 9.7 MB | 8.5 MB | ? |
| http_server | `stdlib/bytes.Bytes.toArray` stdlib/bytes.or:165 `l7 = builtin arr.slice(l2, l3, l6)` | yes | 4,000 | 9.1 MB | 7.9 MB | (g) |
| http_server | `stdlib/bytes.ByteBuilder.constructor` stdlib/bytes.or:270 `l1 = arraynew val []` | yes | 2,000 | 6.9 MB | 6.1 MB | - |
| selfcompile | `opt/params.liveAfter` compiler/opt/params.or:76 `l10 = arraynew val []` | no (range proof) | 107,862 | 5.9 MB | 5.2 MB | ? |
| http_server | `stdlib/net.recv` stdlib/net.or:347 `l10 = builtin net.recv(l0, l1, l9)` | yes | 2,000 | 4.7 MB | 4.1 MB | - |
| selfcompile | `array/map.mapSet<string,check/fnctx.Bind>` array/map.or:207 `arraypush l36, true` | yes | 23,121 | 2.1 MB | 1.9 MB | ? |

## Top 20 allocation sites (all workloads)

Sites are MIR instructions (`function` + block.instruction); the same std function compiled into several workloads is one row. *RC on its objects*: retains + releases the objects allocated there received anywhere. A `*` after the class marks a kind default rather than a reviewed decision.

| # | site | kind | allocations | bytes | RC on its objects | class | workloads | why |
| ---: | --- | --- | ---: | ---: | ---: | --- | --- | --- |
| 1 | `main.make` bench/bintrees/main.or:5 | variant Node(Tree, Tree) | 16,842,752 | 808.5 MB | 16,842,752 | (f) | bintrees | the tree is built, checked and dropped per iteration: a region per iteration (bump allocate, free in one step); the long-lived tree is (f) freeze |
| 2 | `main.make` bench/bintrees/main.or:6 | variant Node(Tree, Tree) | 16,563,135 | 795.0 MB | 16,563,135 | (f) | bintrees | the tree is built, checked and dropped per iteration: a region per iteration (bump allocate, free in one step); the long-lived tree is (f) freeze |
| 3 | `verify/state.mk` compiler/verify/state.or:50 | record LState {k, src} (2 scalars) | 4,088,444 | 196.2 MB | 646,793,200 | (a) | selfcompile | elements of the verifier's `ls: LState[]`: stored inline (2 scalar fields) the array becomes a scalar array, so the 4.1M objects, the retains of every COW copy of `ls` and the dups around `joinLs` disappear |
| 4 | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 2,848,147 | 119.6 MB | 2,861,477 | - | mapfreq, wordfreq, strings +15 more | the result (one allocation per call: the first append copies the immortal "" into a buffer of capacity 9, the other digits are appended in place). The cost is the per-digit loop, not allocations; the second string of `"w" + n.toString()` is counted at the concatenation, class (e) |
| 5 | `stdlib/taskcore.Ring.constructor` stdlib/taskcore.or:19 | class object Ring (5 scalars) | 2,581,847 | 185.9 MB | 12,873,391 | (c) | tasks | loaded from the channel monitor's words, changed and stored back inside one function: scalar-replace it |
| 6 | `stdlib/task.putBox<int>` stdlib/task.or:59 | record Box<T> (1 field) | 1,220,000 | 48.8 MB | 1,220,000 | (g) | tasks | a message is boxed in a one-field record, and the runtime moves it into a second box (its own row): two allocations per send; transfer a scalar payload without boxing (runtime API change) |
| 7 | `stdlib/task.putBox<int>` stdlib/task.or:59 | record (the runtime's transfer box) | 1,220,000 | 48.8 MB | 1,220,000 | (g) | tasks | orin_rt_transfer_put re-boxes the sender's box for the receiving task (see the Box<T> row) |
| 8 | `stdlib/task.Receiver.recv<int>` stdlib/task.or:188 | Option | 1,200,000 | 48.0 MB | 1,200,000 | (a) | tasks | `Some(v)` returned by recv and matched |
| 9 | `main.main` bench/mapfreq/main.or:6 | string ("w" / "item" + n.toString()) | 1,000,000 | 49.6 MB | 1,100,000 | (e) | mapfreq | literal + number: the number string is fresh, unique and dies right there; prepend the literal into it instead of allocating a second string |
| 10 | `main.main` bench/wordfreq/main.or:41 | string ("w" / "item" + n.toString()) | 1,000,000 | 47.7 MB | 1,010,000 | (e) | wordfreq | literal + number: the number string is fresh, unique and dies right there; prepend the literal into it instead of allocating a second string |
| 11 | `array/map.mapGet<string,int>` array/map.or:179 | Option | 950,001 | 38.0 MB | 950,001 | (a) | mapfreq | `Map.get` returns Option<V>; unwrapped / matched at once |
| 12 | `stdlib/http.sliceString` stdlib/http.or:1385 | string (header name / value / token) | 947,252 | 43.8 MB | 2,801,972 | - | http_parse, http_server | the header names and values of the parsed request are its result; one allocation each since bytesToString |
| 13 | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 924,020 | 51.7 MB | 10,995,882 | (a) | http_parse, http_server, bytesstr | a 3-field view created by `Bytes.slice` per chunk / line and dropped after the parse step: unbox the view (pass data/start/len) -- (c) where it does not leave the caller |
| 14 | `opt/analysis.lo` compiler/opt/analysis.or:8 | array<usize> (0-1 elements) | 717,614 | 40.2 MB | 717,614 | (g) | selfcompile | `instrUses` returns a fresh `usize[]` per operand / instruction (`lo(o)` = `[l]` or `[]`) only to be iterated: a visitor or an out-parameter array removes it; (c) would need inlining first |
| 15 | `main.sortInts` bench/qsort_inplace/main.or:13 | Option | 677,698 | 27.1 MB | 677,698 | (a) | qsort_inplace | `stack.pop()` Option unwrapped at once |
| 16 | `main.sortInts` bench/qsort_inplace/main.or:14 | Option | 677,698 | 27.1 MB | 677,698 | (a) | qsort_inplace | `stack.pop()` Option unwrapped at once |
| 17 | `opt/analysis.ancestors` compiler/opt/analysis.or:152 | array<usize> | 654,294 | 31.4 MB | 1,291,002 | (g) | selfcompile | per-call worklists; reuse one buffer per function |
| 18 | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2229 | record Entry {priority, value} | 600,000 | 28.8 MB | 600,000 | (a) | pqueue | returned in Some(..) and destructured by the caller |
| 19 | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2230 | Option | 600,000 | 24.0 MB | 600,000 | (a) | pqueue | `pop().unwrap()`: the Option dies at once |
| 20 | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2231 | Option | 600,000 | 24.0 MB | 600,000 | (a) | pqueue | `pop().unwrap()`: the Option dies at once |

## Top 5 allocation sites per workload

| workload | site | kind | allocations | share | class |
| --- | --- | --- | ---: | ---: | --- |
| selfcompile | `verify/state.mk` compiler/verify/state.or:50 | record LState {k, src} (2 scalars) | 4,088,444 | 16.5% | (a) |
| selfcompile | `opt/analysis.lo` compiler/opt/analysis.or:8 | array<usize> (0-1 elements) | 717,614 | 2.9% | (g) |
| selfcompile | `opt/analysis.ancestors` compiler/opt/analysis.or:152 | array<usize> | 654,294 | 2.6% | (g) |
| selfcompile | `verify/rules.setLs` compiler/verify/rules.or:48 | COW copy of LState[] | 580,599 | 2.3% | - |
| selfcompile | `verify/rules.setLs` compiler/verify/rules.or:48 | COW copy of record State {ls, holes} | 580,401 | 2.3% | - |
| http_server | `stdlib/http.sliceString` stdlib/http.or:1385 | string (header name / value / token) | 17,336 | 12.0% | - |
| http_server | `stdlib/bytes.ByteBuilder.appendString` stdlib/bytes.or:376 | array<u8> (temporary) | 16,000 | 11.1% | (g) |
| http_server | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 13,373 | 9.2% | (a) |
| http_server | `stdlib/http.Headers.get` stdlib/http.or:633 | Option | 9,334 | 6.5% | (a) |
| http_server | `stdlib/http.Headers.constructor` stdlib/http.or:570 | class object Headers | 8,000 | 5.5% | - |
| http_parse | `stdlib/http.sliceString` stdlib/http.or:1385 | string (header name / value / token) | 929,916 | 24.0% | - |
| http_parse | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 910,607 | 23.5% | (a) |
| http_parse | `stdlib/bytes.Bytes.toArray` stdlib/bytes.or:165 | array<u8> | 459,251 | 11.8% | (g) |
| http_parse | `stdlib/http.MessageParser.feed` stdlib/http.or:1615 | array<u8> (empty) | 434,751 | 11.2% | (c) |
| http_parse | `stdlib/http.RequestParser.feed` stdlib/http.or:2658 | pair (in/out result rebuilt) | 428,751 | 11.0% | (a) |
| tasks | `stdlib/taskcore.Ring.constructor` stdlib/taskcore.or:19 | class object Ring (5 scalars) | 2,581,847 | 39.7% | (c) |
| tasks | `stdlib/task.putBox<int>` stdlib/task.or:59 | record Box<T> (1 field) | 1,220,000 | 18.8% | (g) |
| tasks | `stdlib/task.putBox<int>` stdlib/task.or:59 | record (the runtime's transfer box) | 1,220,000 | 18.8% | (g) |
| tasks | `stdlib/task.Receiver.recv<int>` stdlib/task.or:188 | Option | 1,200,000 | 18.5% | (a) |
| tasks | `stdlib/task.putBox<()=>void>` stdlib/task.or:59 | record (the runtime's transfer box) | 100,023 | 1.5% | (g) |
| bintrees | `main.make` bench/bintrees/main.or:5 | variant Node(Tree, Tree) | 16,842,752 | 50.4% | (f) |
| bintrees | `main.make` bench/bintrees/main.or:6 | variant Node(Tree, Tree) | 16,563,135 | 49.6% | (f) |
| bintrees | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 12 | 0.0% | - |
| bintrees | `main.main` bench/bintrees/main.or:28 | string ("w" / "item" + n.toString()) | 4 | 0.0% | (e) |
| bintrees | `main.main` bench/bintrees/main.or:32 | string ("w" / "item" + n.toString()) | 1 | 0.0% | (e) |
| sortedmap | `stdlib/collections.SortedMap.floorKey<int>` stdlib/collections.or:1247 | Option | 362,328 | 19.0% | (a) |
| sortedmap | `stdlib/collections.SortedMap.removeKey<int>` stdlib/collections.or:982 | Option | 215,728 | 11.3% | (a) |
| sortedmap | `stdlib/collections.SortedMap.removeKey<int>` stdlib/collections.or:983 | Option | 215,728 | 11.3% | (a) |
| sortedmap | `main.main` bench/sortedmap/main.or:18 | pair (in/out result rebuilt) | 200,000 | 10.5% | (a) |
| sortedmap | `stdlib/collections.SortedMap.remove<int>` stdlib/collections.or:1157 | Option | 173,685 | 9.1% | (a) |
| pqueue | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2229 | record Entry {priority, value} | 600,000 | 16.7% | (a) |
| pqueue | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2230 | Option | 600,000 | 16.7% | (a) |
| pqueue | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2231 | Option | 600,000 | 16.7% | (a) |
| pqueue | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2232 | Option | 600,000 | 16.7% | (a) |
| pqueue | `stdlib/collections.PriorityQueue.pop<int>` stdlib/collections.or:2262 | Option | 600,000 | 16.7% | (a) |
| mapfreq | `main.main` bench/mapfreq/main.or:6 | string ("w" / "item" + n.toString()) | 1,000,000 | 33.3% | (e) |
| mapfreq | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 999,803 | 33.3% | - |
| mapfreq | `array/map.mapGet<string,int>` array/map.or:179 | Option | 950,001 | 31.7% | (a) |
| mapfreq | `array/map.mapEntries<string,int>` array/map.or:255 | record entry {key, value} | 50,000 | 1.7% | (a) |
| mapfreq | `array/map.buildTab<string>` array/map.or:114 | array<scalar> | 8 | 0.0% | ?* |
| wordfreq | `main.main` bench/wordfreq/main.or:41 | string ("w" / "item" + n.toString()) | 1,000,000 | 49.9% | (e) |
| wordfreq | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 997,837 | 49.8% | - |
| wordfreq | `main.main` bench/wordfreq/main.or:47 | record Entry {word, count} | 5,000 | 0.2% | - |
| wordfreq | `main.main` bench/wordfreq/main.or:33 | array<ref> | 1,024 | 0.1% | ?* |
| wordfreq | `main.main` bench/wordfreq/main.or:30 | array<ref> | 1 | 0.0% | ?* |
| strings | `std/strings.strSplit` std/strings.or:87 | string (split part) | 500,000 | 20.0% | - |
| strings | `std/numbers.strParseInt` std/numbers.or:72 | Option | 500,000 | 20.0% | (a) |
| strings | `main.build` bench/strings/main.or:6 | string ("w" / "item" + n.toString()) | 500,000 | 20.0% | (e) |
| strings | `main.main` bench/strings/main.or:20 | string (temporary) | 500,000 | 20.0% | (g) |
| strings | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 499,995 | 20.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:10 | array<int> | 477,781 | 20.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:11 | array<int> | 477,781 | 20.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:12 | array<int> | 477,781 | 20.0% | - |
| qsort_func | `main.qs` bench/qsort_func/main.or:18 | array<int> | 477,781 | 20.0% | (e) |
| qsort_func | `main.qs` bench/qsort_func/main.or:18 | array<int> | 477,781 | 20.0% | (e) |
| qsort_inplace | `main.sortInts` bench/qsort_inplace/main.or:13 | Option | 677,698 | 50.0% | (a) |
| qsort_inplace | `main.sortInts` bench/qsort_inplace/main.or:14 | Option | 677,698 | 50.0% | (a) |
| qsort_inplace | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 1 | 0.0% | - |
| qsort_inplace | `main.sortInts` bench/qsort_inplace/main.or:9 | array<scalar> | 1 | 0.0% | ?* |
| qsort_inplace | `main.sortInts` bench/qsort_inplace/main.or:21 | COW copy of array<scalar> | 1 | 0.0% | ?* |
| appends | `main.main` bench/appends/main.or:49 | array<int> (1-2 elements) | 100,000 | 50.0% | (c) |
| appends | `main.main` bench/appends/main.or:55 | array<int> (1-2 elements) | 100,000 | 50.0% | (c) |
| appends | `std/numbers.usizeToString` std/numbers.or:16 | string (decimal digits) | 8 | 0.0% | - |
| appends | `main.Buf.constructor` bench/appends/main.or:9 | class object Buf (1 fields) | 1 | 0.0% | ?* |
| appends | `main.Buf.add` bench/appends/main.or:13 | string | 1 | 0.0% | ?* |

## Top RC sites

Retains at borrow candidates (class d: the retained value is only read before its release, MIR analysis), and the allocation sites whose objects receive the most RC operations.

| workload | retain site | MIR | RC ops removed (2 x retains) |
| --- | --- | --- | ---: |
| mutres | `main.Q.stepVoid` bench/mutres/main.or:43 | `l8 = dup l2` | 20,000,000 |
| mutres | `main.main` bench/mutres/main.or:62 | `l47 = dup l2` | 20,000,000 |
| selfcompile | `verify/rules.def` compiler/verify/rules.or:240 | `l30 = dup l29` | 2,109,208 |
| tasks | `main.throughput$closure0` bench/tasks/main.or:87 | `l14 = dup l10` | 2,000,002 |
| http_parse | `stdlib/bytes.ByteBuilder.appendBytes` stdlib/bytes.or:366 | `l9 = dup l1` | 1,836,000 |
| http_parse | `stdlib/bytes.ByteBuilder.appendBytes` stdlib/bytes.or:367 | `l10 = dup l1` | 1,824,000 |
| http_parse | `stdlib/http.RequestParser.isDone` stdlib/http.or:2691 | `l4 = dup l2` | 878,700 |
| http_parse | `stdlib/http.MessageParser.feed` stdlib/http.or:1613 | `l156 = dup l1` | 869,502 |
| http_parse | `main.parseOnce` bench/http_parse/main.or:68 | `l35 = dup l0` | 830,700 |
| http_server | `stdlib/bytes.ByteBuilder.appendBytes` stdlib/bytes.or:366 | `l9 = dup l1` | 821,722 |
| http_server | `stdlib/bytes.ByteBuilder.appendBytes` stdlib/bytes.or:367 | `l10 = dup l1` | 817,722 |
| selfcompile | `syntax/lexer.Lexer.step` compiler/syntax/lexer.or:369 | `l3 = dup l27` | 811,362 |
| http_parse | `main.parseOnce` bench/http_parse/main.or:70 | `l40 = dup l0` | 809,500 |
| http_parse | `main.parseOnce` bench/http_parse/main.or:69 | `l38 = dup l0` | 809,500 |
| http_parse | `stdlib/http.RequestParser.isFailed` stdlib/http.or:2695 | `l4 = dup l2` | 809,500 |

| workload | allocation site | kind | objects | retains + releases on them | per object | class |
| --- | --- | --- | ---: | ---: | ---: | --- |
| selfcompile | `verify/state.mk` compiler/verify/state.or:50 | record LState {k, src} (2 scalars) | 4,088,444 | 646,793,200 | 158.2 | (a) |
| mutres | `main.Reader.constructor` bench/mutres/main.or:7 | class object (the parser / reader) | 2 | 40,000,002 | 20000001.0 | - |
| bintrees | `main.make` bench/bintrees/main.or:5 | variant Node(Tree, Tree) | 16,842,752 | 16,842,752 | 1.0 | (f) |
| bintrees | `main.make` bench/bintrees/main.or:6 | variant Node(Tree, Tree) | 16,563,135 | 16,563,135 | 1.0 | (f) |
| tasks | `stdlib/taskcore.Ring.constructor` stdlib/taskcore.or:19 | class object Ring (5 scalars) | 2,581,847 | 12,873,391 | 5.0 | (c) |
| http_parse | `stdlib/bytes.Bytes.constructor` stdlib/bytes.or:43 | class object Bytes {data, start, len} (view) | 910,607 | 9,282,943 | 10.2 | (a) |
| selfcompile | `lower/state.Locals.fresh` compiler/lower/state.or:51 | record MLocal {name, ty} | 70,885 | 3,789,785 | 53.5 | - |
| selfcompile | `diag/diag.spanTo` compiler/diag/diag.or:46 | record Span {file, start, end} (3 scalars) | 140,688 | 3,766,566 | 26.8 | (a) |
| selfcompile | `verify/verify.entryState` compiler/verify/verify.or:52 | array<ref> | 3,976 | 3,541,438 | 890.7 | - |
| http_parse | `stdlib/http.MessageParser.constructor` stdlib/http.or:1490 | class object (the parser / reader) | 5 | 2,801,313 | 560262.6 | - |
| http_parse | `stdlib/http.sliceString` stdlib/http.or:1385 | string (header name / value / token) | 929,916 | 2,721,960 | 2.9 | - |
| tasks | `stdlib/task.putBox<()=>void>` stdlib/task.or:59 | record (the runtime's transfer box) | 100,023 | 2,500,029 | 25.0 | (g) |

## COW copies

| workload | site | copies | allocations there | class |
| --- | --- | ---: | ---: | --- |
| selfcompile | `verify/rules.setLs` compiler/verify/rules.or:48 `makeunique l7` | 580,599 | 580,599 | - |
| selfcompile | `verify/rules.setLs` compiler/verify/rules.or:48 `makeunique l6` | 580,401 | 580,401 | - |
| selfcompile | `verify/rules.setLs` compiler/verify/rules.or:48 `makeunique l4` | 285,306 | 285,306 | ? |
| selfcompile | `opt/analysis.ancestors` compiler/opt/analysis.or:195 `arraypush l20, l19` | 151,440 | 151,440 | ? |
| selfcompile | `lower/builder.BlockBuilder.emit` compiler/lower/builder.or:96 `makeunique l3` | 123,440 | 123,440 | (e) |
| selfcompile | `lower/builder.BlockBuilder.emit` compiler/lower/builder.or:96 `arraypush l6, l5` | 123,440 | 123,440 | (e) |
| selfcompile | `lower/builder.BlockBuilder.emit` compiler/lower/builder.or:97 `arraypush l8, l7` | 123,440 | 123,440 | (e) |
| selfcompile | `verify/rules.killBorrows` compiler/verify/rules.or:139 `makeunique l20` | 54,754 | 54,754 | - |
| selfcompile | `verify/rules.killBorrows` compiler/verify/rules.or:139 `makeunique l21` | 54,754 | 54,754 | - |
| selfcompile | `syntax/parser.Parser.expectP` compiler/syntax/parser.or:582 `makeunique l2` | 54,382 | 54,382 | ? |

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
