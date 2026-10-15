# JSX in Orin

Server-side HTML with TSX syntax, rendered to one string, escaped by construction. Design and rationale:
[ADR-0043](decisions/0043-jsx-and-std-html.md). Library: [`std:html`](std.md#stdhtml).

```tsx
import { Html, render, document } from "std:html";

type Product = { id: int; name: string; price: int; url: string; };

function Row(p: Product): Html {
  return <tr data-id={p.id} class={p.id % 2 == 0 ? "even" : "odd"}>
    <td>{p.name}</td>
    <td class="price">{p.price}</td>
    <td><a href={p.url}>details</a></td>
  </tr>;
}

function Layout(title: string, children: Html): Html {
  return <html>
    <head><title>{title}</title></head>
    <body><h1>{title}</h1>{children}</body>
  </html>;
}

function main(): void {
  const products = [Product { id: 1, name: "Tom & Jerry", price: 3, url: "/p/1" }];
  const page = <Layout title="Catalog">
    <table>{products.map(p => <Row p={p} />)}</table>
  </Layout>;
  console.log(document(page));   // "<!DOCTYPE html>" + the page
}
```

## What you can write

| Construct | Example | Notes |
|---|---|---|
| element | `<div class="a">..</div>`, `<br />` | lower-case names, `-` allowed (`<my-widget>`) |
| fragment | `<>..</>` | no attributes |
| string attribute | `title="Tom &amp; Jerry"`, `title='say "hi"'` | TSX rules: no backslash escapes, entities decoded |
| expression attribute | `size={n}`, `href={url}`, `disabled={off}` | `string` (escaped), numbers, `bool` (present / absent) |
| bare attribute | `required` | the value `true` |
| text | `Hello, world &copy;` | lines trimmed and joined with one space; entities decoded |
| expression child | `{name}`, `{count}`, `{html}`, `{items.map(i => <li>{i}</li>)}` | `string` (escaped), numbers, `Html`, `Html[]` |
| component | `<Card title="x" count={3}>body</Card>` | a function returning `Html`; attributes are arguments by parameter name; children are the parameter `children: Html` |

Not supported yet: `{...spread}` attributes, `<a.b>` member tags, `xlink:href`, `bool` or `Option` children (write
`c ? <x /> : <></>`), `key`.

## Safety

- Every dynamic string is escaped (`&` `<` `>` `"` `'`). Static text is escaped at compile time with the same table.
- URL attributes (`href`, `src`, `action`, ...) with a computed value are sanitised: `javascript:`, `data:` and any other
  scheme than `http`, `https`, `mailto`, `tel` become `about:invalid#orin-unsafe-url`.
- `onclick={...}` and other computed event handlers are rejected (E0493); `<script>` / `<style>` take only static text.
- `Html` cannot be built or changed outside `std:html` (E0495). Raw HTML only through `trustHtml(raw)`, which shows up
  in review and in OSIG as a call.

## Performance

A JSX root compiles to one string buffer: all tags and static text are merged at compile time and nested elements are
appended in place into the same buffer; dynamic values are escaped (no allocation when nothing needs escaping) and
appended. There is no virtual DOM and no node object. Each component call returns one `Html`. See docs/benchmarks.md
"HTML rendering" for JSX against hand-written string building, C and Go.

## Error codes

| Code | Meaning |
|---|---|
| E0490 | JSX in a program that does not import `std:html` |
| E0491 | component: unknown, not a function, unknown / missing attribute, children without a `children` parameter, result not `Html` |
| E0492 | a value of a type that cannot be rendered there (e.g. a `bool` child, an `Html` attribute) |
| E0493 | unsafe: computed event handler attribute, computed `<script>` / `<style>` content |
| E0494 | malformed element: children of a void element, invalid tag or attribute name |
| E0495 | `Html { .. }` or `h.html = ..` outside `std:html` |
| E0200 / E0100 | syntax: mismatched closing tag, spread, duplicate attribute / unterminated element, `}` or `>` in text |

## Testing the implementation

- `python3 tools/run_tests.py --suite next --filter jsx` — the JSX conformance and error tests.
- `tools/test_std.sh tests/std/html_test.or`, `python3 tools/mutate_std.py --module html` — `std:html`.
- `python3 tools/mutate_jsx.py -j 2` — builds the compiler with each deliberate bug in the JSX lexer, parser and checker
  and requires the JSX tests to catch it (one compiler build per mutant). Last run (2026-10-15): 23 mutants, 23 killed.
- `python3 tools/bench.py --only html,html_hand --no-selfcompile` — the benchmark.
