# ADR-0043: JSX and `std:html` — server-side HTML as a fused string, safe by construction

Status: accepted (2026-10-15, merged as PR #72); the semantics (§2) are superseded by ADR-0044 (OX: generic providers);
the syntax (§1) and the fused lowering (§3) remain, as the `Markup` provider kind. Related: ADR-0016 (additive syntax after the
freeze needs its own ADR), ADR-0030 §4 (direction for JSX), ADR-0038 (performance model: no hidden allocation, fusion),
ADR-0022 (template literals: the lowering JSX reuses), ADR-0028 (contract quality), docs/jsx.md (user guide),
docs/std.md "std:html".

## Context

The roadmap (vision §14 "JSX-Aufteilung", ADR-0030 §3-4, roadmap phase 8) asks for server-side JSX on a `std:html`
library: escaping must be safe by construction, raw HTML only through an explicit and auditable `trustHtml`, no virtual
DOM. The project owner asked (2026-10-15) for a first vertical slice: elements, attributes, expressions, nested
components and safe escaping, lowered into the existing HIR → MIR pipeline so that the ownership verifier, the
optimiser, inlining and both backends work on it unchanged, with direct, fused output and as few heap allocations as
hand-written string building; benchmarked against hand-written HTML generation.

What a server renderer must do per request is build one string. A virtual DOM (React's model) allocates a node per
element and walks the tree again to print it: two passes and O(nodes) allocations for nothing on the server.
ADR-0030 §4 sketched a `JsxFactory` interface with typed constructor calls; that keeps a tree (or at least one virtual
call and one value per element) and leaves fusion to an optimiser that does not exist.

## Decision

### 1. Syntax (TSX-compatible subset)

```tsx
import { Html, render } from "std:html";

function Card(title: string, featured: bool, children: Html): Html {
  return <section class={featured ? "card featured" : "card"}>
    <h2>{title}</h2>
    {children}
  </section>;
}

const page = <main><Card title="Tom & Jerry" featured>Hello, {user.name}!</Card><br /></main>;
console.log(render(page));
```

- An element `<name attrs>children</name>`, a self-closing `<name attrs />`, a fragment `<>children</>`.
- Attributes: `name="text"` (a JSX string: `"` or `'`, no backslash escapes, character references decoded),
  `name={expr}`, or a bare `name` (the value `true`). Names may contain `-` (`data-id`, `aria-label`) and may be
  keywords (`class`, `for`). Duplicate attributes are a syntax error.
- Children: text, `{expr}`, nested elements. Text follows the React/TypeScript rules: lines are trimmed, lines that are
  only whitespace are dropped, the rest joined with one space; `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` `&nbsp;`, common
  typographic names and `&#N;` / `&#xH;` are decoded. `{}` and `{/* comment */}` are no child. `}` and `>` are not
  allowed in text (write `{"}"}` or `&gt;`).
- A tag whose name starts with an upper-case letter is a **component**, any other tag an **HTML element**.
- Not in this slice (syntax errors or not parsed): spread attributes `{...props}`, member tags `<ui.Card>`, namespaced
  names `xlink:href`, `key`.

**Where `<` starts JSX.** The lexer decides, as JavaScript tools decide regular-expression literals: `<` followed by a
letter or `>` starts an element when the previous token cannot end an operand — after `(` `,` `=` `=>` `?` `:` `{` `[`
`;`, an operator, `return` or `${`, or at the start of the file. After a name, a literal, `)`, `]` or `}` it stays the
less-than operator or the start of type arguments (`a <b`, `id<int>(x)`, `Map<K, V>`, `xs[0] <y`), so no existing
program changes meaning (the whole conformance suite is unchanged; `tests/next/run/jsx_lexer.or` pins the cases).

**Lexing.** JSX has its own lexer modes on the same context stack as template literals (`Lexer.ctx`: template
interpolation, JSX `{..}`, opening tag, children, closing tag), so the parser stays a plain recursive-descent parser
over tokens: `KJsxOpen` (`<` / `</`), `KJsxEnd` (`>` / `/>`) and `KJsxText` (cooked text, never empty) are new token
kinds; inside a tag names are `KIdent`, values `KStr`, braces `KPunct`, and between `{` and `}` the ordinary tokens.
The AST gets one expression node, `EJsx(JsxElement)` (`compiler/syntax/ast.or`), with the helpers `jsxExprs`,
`jsxMapExprs` and `jsxComponents` that every walker (symbol index, quality lints, runtime-check rewriting) uses.

### 2. Semantics

A JSX expression has the type `Html` of `std:html`: `type Html = { html: string; }`, rendered, trusted HTML.

| Written | Becomes |
|---|---|
| `<div a="x" b={e}>..</div>` | `<div a="x" b="..">..</div>`: tags and static parts are text, attributes in written order |
| `{s}` with `s: string` (child) | `escape(s)`: `&` `<` `>` `"` `'` → entities |
| `{h}` with `h: Html` / `Html[]` | inserted unchanged / all elements concatenated (`joinAll`) |
| `{n}` with an integer or float | its decimal text (no escaping needed) |
| `b={s}` with `s: string` | `b="escape(s)"`; for URL attributes (`href`, `src`, `action`, `formaction`, `cite`, `poster`, `background`, `manifest`, `ping`, `data`) `escapeUrl(s)`: a scheme other than `http`, `https`, `mailto`, `tel` becomes `about:invalid#orin-unsafe-url` |
| `b={c}` with `c: bool`, bare `b` | ` b` when true, nothing when false (HTML boolean attributes) |
| void element (`br`, `img`, `input`, ...) | no closing tag; children are an error (E0494) |
| `<script>`, `<style>` | only static text and string literals, written unescaped (their content is not HTML, so escaping would not make a value safe) |
| `<Card a={x} b>kids</Card>` | the call `Card(..)` with the attributes as arguments **by parameter name** (any order), the children as the argument of the parameter `children` (an `Html`; empty when none are written); the function must return `Html` |

Components are ordinary functions: generic functions work, recursion works, imported functions work, the call is a
normal call for OSIG, effects, purity and the LSP (the tag name is a reference to the function). There is no props
record: passing the attributes as arguments allocates nothing and lets the type checker report a wrong attribute at
its own position (`expected int, found string`).

**Safety rules (XSS by construction).**
- `Html` is **sealed**: outside `std:html` a record literal `Html { .. }` and an assignment to `h.html` are E0495. So an
  `Html` value is only ever produced by JSX (escaping every dynamic text), `text(s)` (escaped) or `trustHtml(raw)` (the
  explicit escape hatch, visible as a call in OSIG and in review). Reading `h.html` is allowed.
- A computed value for an event handler attribute (`on*`, any case) is E0493: it would be JavaScript. A string literal
  is allowed (author-written code).
- A computed child of `<script>` / `<style>` is E0493.
- Static text and static attribute values are escaped at compile time with the same table as `std:html.escape`
  (`check/jsx.or htmlEscapeStatic`); `tests/next/run/jsx_escape_diff.or` checks the two agree on all 256 byte values, in
  text and attributes, static and dynamic.
- Honest limits: escaping makes values safe in HTML text and quoted attribute values. CSS inside a dynamic `style`
  value, URLs inside `srcset`, and JavaScript contexts are not parsed (as in React); `trustHtml` is trusted by
  definition.

Error codes: E0490 (JSX in a program that does not load `std:html`), E0491 (component: unknown, not a function,
unknown / missing attribute, children without a `children` parameter, result not `Html`), E0492 (a child or attribute
value of a type that cannot be rendered, e.g. `bool` children: write `c ? <x /> : <></>`), E0493 (unsafe: computed
event handler, computed `<script>` / `<style>` content), E0494 (malformed element: void element with children, invalid
tag or attribute name), E0495 (`Html` built or changed outside `std:html`). Syntax: E0200 (mismatched closing tag,
spread, duplicate attribute), E0100 (unterminated element, `}` / `>` in text).

### 3. Lowering: one fused buffer per root, no tree

The checker (`ExprChecker.jsx`, `compiler/check/expr.or`; rules in `compiler/check/jsx.or`) lowers a JSX root
directly to HIR, the way a template literal is lowered (ADR-0022):

```
<tr class="row"><td>{name}</td><td>{price}</td></tr>
  ==>  Html { html: (("<tr class=\"row\"><td>" + escape(name)) + "</td><td>") + price.toString() + "</td></tr>" }
```

- The output is a list of pieces; adjacent static pieces (tags, attribute names, static text escaped at compile time,
  `c ? "a" : "b"` with literal branches escaped at compile time) are **merged into one literal**.
- **Nested HTML elements and fragments are flattened into the parent's buffer**: the whole tree of one root is one
  left-nested concatenation, which the existing lowering turns into one owned buffer appended in place
  (`IStrAppend` / `IStrPrepend`, MIR v2.3), with geometric growth. No intermediate string per element, no node objects.
- Dynamic pieces are calls of `std:html` (`escape`, `escapeUrl`, `joinAll`, all pure Orin with contracts) or number
  conversions. `escape` returns its argument itself when nothing needs escaping (no allocation, one scan).
- A component is a call; its `Html` is inserted by reading its field (`XField`) into the caller's buffer.
- The result is wrapped in the sealed `Html` record once per root.

Because the result is plain HIR (strings, calls, conditionals, one record), everything downstream works unchanged:
the MIR ownership verifier checks every JSX function, closure fusion applies to `items.map(i => <li>{i}</li>)`, purity
and effects see the `std:html` calls, both backends and the prune pass need nothing new. MIR of a row component
(`orin mir`): one buffer, five appends of merged static text, three escape / conversion calls, one `struct` — the same
shape as the hand-written concatenation.

### 4. Tooling

- `orin fmt` prints JSX exactly as written (like template literals, ADR-0022): one canonical form is a follow-up.
- The symbol index records component tags as references (LSP go-to-definition / find references, OSIG calls).
- The contract verifier (`orin verify --contracts`) does not translate JSX (unsupported expression, as other strings).

## Evidence

- Tests: `tests/next/run/jsx_basic.or` (elements, attributes of every type, text rules, entities, fragments, void and
  raw-text elements, `Html[]` children), `jsx_components.or` (attributes by name, children, recursion, a generic
  component, equality with a direct call), `jsx_lexer.or` (`<` next to comparisons, generics, indexing, templates),
  `jsx_escape_diff.or` (differential: compile-time vs run-time escaping, all byte values), 20 error tests
  `tests/next/errors/jsx_*.or` (every code, every safety rule).
- `std:html`: 18 `@Test`s run with and without runtime contract checking, a differential test against an executable
  specification of `escape`, 41 mutants all killed (`tools/mutate_std.py --module html`); docs/std.md.
- Compiler mutation check: `tools/mutate_jsx.py` builds the compiler with each of 23 deliberate bugs in the JSX lexer,
  parser and checker (missing escapes, unsanitised URL attributes, accepted event handlers, unsealed `Html`, broken text
  rules, the `<` heuristic) and requires the JSX tests to fail: 23 of 23 killed (2026-10-15).
- Benchmark `bench/html` (JSX) against `bench/html_hand` (hand-written Orin with the same `std:html` functions), C and Go:
  byte-identical output. JSX executes 3.99 G instructions against 4.71 G for the hand-written concatenation (15 % fewer)
  and 1.58 G for C, with 30 % fewer allocations than the hand-written version (docs/benchmarks.md "HTML rendering").
- The bootstrap fixed point holds with JSX in the compiler (`stage2.c == stage3.c`); all conformance, std, fmt and
  tooling suites pass unchanged.
- Differential backends: the JSX tests are ordinary conformance tests, so `tools/differential.sh` (C vs LLVM, opt,
  fuse) covers them.

## Not done (follow-ups, in order of expected gain)

1. ~~**Pre-sized buffer.**~~ Done (ADR-0044, "Pre-sized buffer"): a root starts from `str.withCapacity(hint)`;
   `string_grows` 4.23 M -> 0.25 M and executed instructions 3.99 G -> 3.10 G on the benchmark.
2. **Append without temporaries.** Integers and escaped text are converted into a temporary string and then appended; an
   append-escaped / append-int primitive would write straight into the buffer.
3. **Component fusion.** A small component could be inlined (`@Inline` / the inliner) so that its tags merge into the
   caller's buffer; `Html[]` built by `map` and inserted once could be fused into the parent buffer (ADR-0038 fusion of
   `map` + `joinAll`), removing the per-row `Html` record and the second copy.
4. **Streaming.** Rendering into a response stream (`std:net`) instead of a string, for large pages.
5. Syntax: spread attributes (needs a props record design), member tags, `Option<Html>` children, `xlink:href`,
   a canonical formatter layout, translation of JSX in contracts.
6. Context-aware escaping for `style` (CSS) and `srcset`.

## Consequences

- JSX is additive (ADR-0016): a program without JSX lexes, parses, checks and compiles to byte-identical output
  (the conformance suite, the self-compile fixed point). The cost is three token kinds, one AST node and one checker
  section; every exhaustive `match` over tokens and expressions had to name them.
- JSX is library-backed: the compiler knows `std:html` by unit name (`$stdlib/html`) and calls four of its functions.
  Renaming them is a compiler change.
- The safety argument rests on two facts the compiler enforces (`Html` sealed; every dynamic piece goes through
  `escape` / `escapeUrl`, every static piece through the identical compile-time table) and on `std:html`'s contracts and
  tests. It is not a proof: `escape`'s `@Ensures` (no `<`, `>`, `"`, `'` in the result) are runtime-checked and tested,
  not verified.
