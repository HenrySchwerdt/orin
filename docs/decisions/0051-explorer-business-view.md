# ADR-0051: The explorer's business view: rules, use cases, capabilities and behaviour changes in plain language

Status: Accepted (2026-10-16). Builds on ADR-0050 (the code explorer), ADR-0012 (contract clauses), ADR-0037 (effects) and ADR-0023 (OSIG).

## Motivation

The explorer of ADR-0050 shows what any code-analysis tool shows: modules, symbols, signatures, call graphs. A product owner or a business person cannot do much with it. What they ask is different: *What can this software do? Which rules does it keep? What is it allowed to touch? What changed in this release that I should care about?* Orin has unusual answers to all four, because the language writes the answers down: contract clauses are business rules, exported entry points are use cases, effects are capabilities, and `orin diff` already knows what changed. The business view presents these facts, and nothing else, in words a non-programmer can read.

## Decision

### 1. The view

A second group of pages in the same site, first in the navigation ("Business view"), the existing pages unchanged under "Technical view". It reads the same two inputs as before (an OSIG snapshot, optionally an `orin diff --format=json` report) and needs no compiler change.

| Page | Content |
|---|---|
| Summary (`business.html`) | cards (use cases, rules, rules with a known status, kinds of access, behaviour changes), the main use cases, the rules most use cases rely on, what the software may touch, the latest changes, a short glossary. No signature appears. |
| Use cases (`usecases.html`, `u/<slug>.html`) | one card per use case; a page per use case: the description, what it may do, the rules it relies on and, folded away under "Technical details", the signature and a link to the symbol page. |
| Business rules (`rules.html`) | every `@Requires`, `@Ensures` and `@Invariant` clause as a sentence, grouped by module ("area"), each with its status, the declaration it applies to and the number of use cases that rely on it. |
| Capabilities (`capabilities.html`) | what the software may do (table: capability, area, permission, use cases, modules). |
| What changed (`behaviour.html`, only with `--diff`) | added, removed and changed capabilities, rules and use cases, in sentences. Links to the technical changes page. |

### 2. Where each concept comes from

- **Use case**: a node with `entry: true` of kind Function or Method (OSIG: `main`, exported functions, exported public methods), constructors excluded. Its title is derived from the name (`saveOrder` is "Save order", `main` is "Start the program", a method is "Cart: add"); its description is the first paragraph of its documentation comment (ADR-0050 section 5), without code and tags. A use case without a comment says "No description yet" and the summary counts how many are described. A signature that mentions `Request` and `Response` is marked "HTTP handler (recognised by its signature)"; nothing else is inferred, so this is a hint, not a router analysis (the standard library has no HTTP framework yet).
- **Rule**: a `Contract` node. Its text is turned into a sentence by a small, total reader of the expression: comparisons with zero are worded ("positive", "zero or greater"), `x.length > 0` is "must not be empty", `&&` gives one sentence per part, `||` an "either ... or", `=>` an "if ... then", a call is "the check f(x) must be true". Anything it does not understand is written as "The condition ... must hold": it never drops or invents a condition. The wording follows the kind (`requires`: "must be", `ensures`: "will be", `invariant`: "is always"). Rules are grouped by the module of the clause.
- **Rules a use case relies on**: the clauses of the use case itself and of everything it can reach through `CALLS` edges (all evidence classes), plus the invariants of the classes whose methods it reaches. The page says which are written on the use case and which on what it uses.
- **Capability**: a `MAY_PERFORM` edge (ADR-0037 D2, already transitive) to an effect node. Operations are phrased as what the software may do: `Fs.ReadFile` "read files", `Fs.WriteFile` "write files", `Clock.Now` "read the clock", `Console.Write` "write messages to the console", `Process.Spawn` "start other programs", a `Net.*` or `Http.*` operation "open network connections", `Unknown.*` "do something the analysis cannot see". An operation without a phrase is shown as "perform <operation>" instead of being guessed. The permission is the grant of the effect node ("file-system permission"; "none needed" for ambient effects). Per use case the page says whether it does it itself, through which callee (the `next` field) or possibly (it cannot be ruled out).
- **Behaviour change**: computed from the diff and the head snapshot, in this order of importance: capabilities (the use cases whose entry paths reach a function that gained or lost an effect, from the `reach` of every effect change; "the whole software may now ..." when no function of the head had that effect except those that gained it, "capability gone" for the reverse), rules (added, removed, changed with the old wording), use cases (added, removed, changed signature; a possible rename of an entry point is one line, not a removal plus an addition). Changes that are not business-relevant (an edge, a private symbol) stay on the technical changes page. The diff model gained the `entry` flag of a symbol and the `reach` of an effect change, both fields `orin diff` already writes.

### 3. Assurance: what the snapshot knows and what it does not

The question about a rule is whether it is **proved** (`orin verify --contracts` shows it always holds), **checked at run time** (the compiler emits a check) or **open**. OSIG `0.3` does not carry that outcome: a `Contract` node has text and a span only, and the verifier's result lives in a separate run. This is a gap of the data, not of the view, and the view does not paper over it: a clause shows status **Unknown** unless the node carries the optional field `assurance` with one of `proved`, `runtime`, `open`. The explorer reads that field already (any other value reads as unknown), so once `orin graph` writes it (a follow-up that needs a compiler change and an `osig/0.4`, which this change deliberately does not make) the status appears without changing the explorer. Until then the rules page says in a notice that every status reads Unknown because the snapshot does not record it, and the summary counts "rules with a known status: 0 of N". The legend explains all four states.

### 4. Rules of the pages

The rules of ADR-0050 section 3 apply: OX components over typed records, escaping by `std:html`, no inline script or style (the business view needs no script at all), relative links only, byte-deterministic output, light and dark theme from the shared tokens. The stylesheet is a second asset, `assets/business.css` (`theme/business.css`, generated into `src/business_css.or` by `gen_assets.sh`), linked only by business pages. Status, kind of change and evidence are always words, never colour alone. Long lists are capped with a statement (300 use cases, 500 rules, 100 changes per area, 40 inherited rules per use case); the page of every use case is still written.

### 5. Tests

`tests/business_test.or`: the sentence reader on every comparison, polarity, kind, conjunction, alternative, implication, emptiness, call and malformed or hostile input; titles, descriptions and capability wording; use cases collecting rules (own first) and capabilities; the behaviour diff (new, removed and changed rule; new and removed use case; rename as one change; capability per use case through entry paths; new for the whole package versus pre-existing; no changes); hostile text escaped on every business page. `test.sh` additionally checks that the pages exist, that there is no behaviour page and no link to it without `--diff`, and the golden site (the fixture `testdata/shop` gained a rule that changes, a rule that disappears with a renamed function, and a function that starts reading the clock).

## Consequences

- Product owners get a first page that answers their questions without reading code; developers keep the technical view, one click away on every page.
- The rule wording is a heuristic reading of an expression, tested but not a formal translation; the technical symbol page always shows the exact clause.
- The assurance column is honest but reads "Unknown" until OSIG carries verifier outcomes (open item).
- Shared files changed minimally (`components.or`: the nav; `model.or`: three fields; `site.or`, `main.or`: registration); everything else is new files.

## Non-goals

Natural-language generation beyond fixed templates, guessing the intent of code, an HTTP route analysis, running the verifier from the explorer, and effects more precise than the analysis (ADR-0037).
