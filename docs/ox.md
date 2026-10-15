# OX in Orin

OX is Orin's markup notation: TSX-like elements, attributes and children that a **library** gives a meaning. The
language owns the syntax, the library (the *provider*) owns the semantics: which elements and attributes exist, how text
is encoded and what a markup expression evaluates to. `std:html` is one provider (server-side HTML, escaped by
construction, rendered into one string); you can write others (XML, a widget tree, a DOM). Design and rationale:
[ADR-0044](decisions/0044-ox-generic-markup.md) (semantics) and [ADR-0043](decisions/0043-jsx-and-std-html.md) (syntax and
lowering). Libraries: [`std:html`](std.md#stdhtml), [`std:ox`](std.md#stdox).

```tsx
import ox from "std:html";
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

## The provider

A file that contains markup selects its provider with

```ts
import ox from "std:html";
```

`import ox from "M";` binds no name, there is at most one per file, and `M` is any module, standard or yours. Without it
markup is an error (E0490). The provider is lexical and explicit: every file names its own, there is no default, and the
compiler knows no library by name. Migrating an ADR-0043 program is adding this one line.

## What you can write

| Construct | Example | Notes |
|---|---|---|
| element | `<div class="a">..</div>`, `<br />` | lower-case start, then letters, digits, `-`, `_` (`<my-widget>`) |
| fragment | `<>..</>` | no attributes |
| string attribute | `title="Tom &amp; Jerry"`, `title='say "hi"'` | TSX rules: no backslash escapes, entities decoded |
| expression attribute | `size={n}`, `href={url}`, `disabled={off}` | checked against what the provider or the component accepts |
| bare attribute | `required` | the value `true` |
| spread | `<Card {...props} title="x" />` | every field of the record `props` is an attribute (on a `Markup` provider's elements as `f={props.f}`, see below) |
| text | `Hello, world &copy;` | lines trimmed and joined with one space; entities decoded |
| expression child | `{name}`, `{count}`, `{h}`, `{items.map(i => <li>{i}</li>)}` | see the provider |
| component | `<Card title="x" count={3}>body</Card>` | an upper-case tag is a call of the function `Card` |
| member tag | `<ui.Card title="x">body</ui.Card>`, `<this.Row a="1" />` | a dotted path whose last segment starts upper-case: a call of the method `Card` of the value `ui` |
| named slot | `<Dialog><:header>..</:header>body</Dialog>` | directly inside a component or member tag; fills the parameter `header` |

Not supported: namespaced names `xlink:href`, `key`.

## Two kinds of provider

`M` exports `function ox()` whose body is one `return` of a literal. The types are in [`std:ox`](std.md#stdox). The
function is type-checked like any function but never called: the compiler reads the literal and calls the functions it
names directly. Anything else in `ox()` is E0490.

### `Markup<R>`: serialise to text (`std:html`)

Intrinsic elements (lower-case tags) are written as text in one fused buffer; the result of a root is `wrap(buffer)`.
Everything HTML-specific is data in the literal:

```ts
export function ox(): Markup<Html> {
  return Markup<Html> {
    wrap: trustHtml, embed: render, embedAll: joinAll, text: escape, attr: escape,
    rules: [AttrRule { names: ["href", "src", ...], prefix: "", convert: Some(escapeUrl) },
            AttrRule { names: [], prefix: "on", convert: None }],
    escapes: [Escape { char: "&", encoded: "&amp;" }, Escape { char: "<", encoded: "&lt;" }, ...],
    voidTags: ["area", "base", "br", ...], voidEnd: ">", rawTextTags: ["script", "style"], presenceAttrs: true,
  };
}
```

| Written | Text |
|---|---|
| `<t ..>kids</t>` | `<t` attributes `>` kids `</t>`; a tag in `voidTags` ends with `voidEnd` and has no children (E0494) |
| `a="s"`, `a={"s"}` | ` a="` static encoding of `s` `"` (the `escapes` table, applied at compile time) |
| `a={s}`, `s: string` | ` a="` `convert(s)` of the first matching rule, else `attr(s)` `"`; a matching rule with `convert: None` makes it an error (E0493) |
| `a={n}`, number | ` a="` decimal text `"` |
| `a={b}`, bare `a` | ` a` or nothing when `presenceAttrs`; E0492 otherwise |
| `{s}` child, `s: string` | `text(s)` |
| `{h}` / `{hs}` child of type `R` / `R[]` | `embed(h)` / `embedAll(hs)` |
| `{n}` child, number | decimal text |
| text, `{"s"}`, `{c ? "a" : "b"}` | static encoding at compile time |
| children of a `rawTextTags` tag | static text only, unencoded, no `</`; anything computed is E0493 |
| `a={o}`, `o: Option<T>` | nothing for `None`, ` a="..."` for `Some(v)` as if written `a={v}`; a `convert: None` rule still rejects it (E0493) |
| spread `{...r}` | `r` (a record, else E0492) is evaluated once, then each field `f` in declaration order is the attribute `f={r.f}` at that position, with every rule above applied by the field name |
| named slot | E0491 (an intrinsic element has no parameters) |

A rule matches attribute `a` when `a` is in `names` or starts with the non-empty `prefix`, compared ASCII
case-insensitively (`HREF={u}` is a URL attribute).

When a name occurs more than once on an element, through a spread or written (compared ASCII case-insensitively), the
one written later wins and the others are left out of the output; every value is still evaluated exactly once, in
source order. Two attributes written with the same name stay a syntax error. A field of a spread record that has no
valid attribute type is E0492 (naming the field); a field named like a `convert: None` rule (`onclick`) is E0493.

### `Components<R>`: build values

An intrinsic tag `t` is the provider's exported function `t`, called like a component. Text where an `R` is expected is
`text(s)`, several children where one `R` is expected are `fragment([..])`.

```ts
// widgets.or
export type Widget = WLabel(string) | WColumn(int, Widget[]) | WGroup(Widget[]) | WText(string);
export function plain(value: string): Widget { return WText(value); }
export function group(items: Widget[]): Widget { return WGroup(items); }
export function label(value: string): Widget { return WLabel(value); }
export function column(spacing: int, children: Widget[]): Widget { return WColumn(spacing, children); }
export function ox(): Components<Widget> {
  return Components<Widget> { fragment: group, text: plain };
}

// main.or
import ox from "./widgets";
import { Widget } from "./widgets";
const ui: Widget = <column spacing={2}><label value="hi" />and text</column>;
// column(2, [label("hi"), plain("and text")])
```

Complete conformance providers: `tests/next/run/ox_widgets/` (a widget tree) and `tests/next/run/ox_xml/` (XML with its
own escape table, `/>` void tags, no presence attributes and a static-only attribute prefix).

## Components

An upper-case tag `C` names a function in scope. The element is a call of `C`:

- each attribute fills the parameter of the same name; `{e}` is checked against the parameter type, so
  `onClick={() => save()}` works where the parameter has a function type;
- a spread `{...r}` fills one parameter per field of `r` (evaluated once); a field without a parameter is E0491; when an
  attribute and a spread name the same parameter, the one written later wins (both are evaluated);
- a parameter of type `Option<T>` may be left out (it is `None`); any other missing parameter is E0491;
- the children fill `children` (the default slot), a `<:name>` slot fills the parameter `name`; an attribute and a slot for
  the same parameter, two slots of one name, or a slot without a parameter are E0491;
- **evaluation order is source order**: attributes written in another order than the parameters are evaluated left to
  right into temporaries before the call; every value is evaluated once.

### Member tags

`<ui.Card title="x">body</ui.Card>` is the method call `ui.Card(title: "x", children: ..)`, with exactly the rules above:
attributes fill the method's parameters by name, spreads, omitted `Option` parameters, the default slot, `<:name>` slots
and source-order evaluation all work the same, and the result is checked where the element is used. `ui` is a class
instance or an interface value, `this.Row` calls a method of the current class from inside it, and the prefix may be a
path of field reads (`<app.theme.Button>`); the closing tag repeats the whole path (`</app.theme.Button>`). The prefix is
only names, `this` and fields, so reading it at the call is the same as evaluating it first.

A member that is not a method (a field of function type has no parameter names) or does not exist is E0491. A dotted tag
whose last segment is lower-case (`<ui.card>`) is a syntax error (E0200): no provider element has a dotted name.

### Slots

The children of a slot (and of a fragment) are checked against the expected type `T`. Whitespace-only text is dropped.

| `T` | children | value |
|---|---|---|
| `R` of a `Markup` provider | any | the fused buffer of the children, `wrap(..)` |
| `R` of a `Components` provider | one child of type `R` | that child |
| `R` of a `Components` provider | otherwise | `fragment([c1, .., cn])` |
| `E[]` | any | `[c1, .., cn]`; an `{x}` of type `E[]` is spliced in |
| `Option<E>` | none / one | `None` / `Some(c1)`; more is E0491 |
| `string` | text, strings, numbers | their concatenation (not encoded: a string, not markup) |
| any other | exactly one child of type `T` | that child (E0491 otherwise) |

A child is converted to `E`: an element is checked against `E`; text or a `string` where `E` is `string` stays a string,
where `E` is a `Components` provider's `R` it is `text(s)`; anything else of the wrong type is E0492. A slot with no
children is the empty value of `T` (`[]`, `None`, `""`, `wrap("")`, `fragment([])`).

```tsx
function Dialog(title: string, header: Widget, children: Widget[], footer: Option<Widget>): Widget { .. }

<Dialog title="Delete?">
  <:header><label value="Really?" /></:header>      // header: Widget, required
  <label value="This cannot be undone." />          // children: Widget[]
  <:footer><button title="Delete" /></:footer>      // footer: Option<Widget>, may be omitted
</Dialog>
```

## Safety

- `Html` (and any `@Sealed` record) can only be built or changed in its own module (E0495). `@Sealed` is for record
  types; elsewhere it is E0440. Raw HTML only through `trustHtml(raw)`, which shows up in review and in OSIG as a call.
- With `std:html`: every dynamic string is escaped (`& < > " '`), static text with the same table at compile time; URL
  attributes (`href`, `src`, `action`, ...) with a computed value are sanitised (`javascript:`, `data:`, ... become
  `about:invalid#orin-unsafe-url`); computed `on*` event attributes are rejected (E0493); `<script>` / `<style>` take
  only static text.
- A spread cannot smuggle an event handler or an unsanitised URL into an element: the spread is expanded at compile
  time and the rules apply by field name, so an `onclick` field is E0493 and an `href` field is sanitised like `href={..}`.
- A provider can still declare a wrong rule (a missing escape). Test its static encoding against its run-time one the way
  `tests/next/run/ox_escape_diff.or` does for `std:html`.

## Performance

For a `Markup` provider a root compiles to one string buffer: tags and static text are merged at compile time and nested
elements are appended in place; dynamic values go through the provider's `@Inline` functions. There is no virtual DOM and
no node object. See docs/benchmarks.md "HTML rendering".

## Error codes

| Code | Meaning |
|---|---|
| E0490 | markup without `import ox from ".."`, or the provider's `ox()` does not return a literal |
| E0491 | component: unknown, not a function, unknown / missing attribute, unknown slot, attribute and slot for one parameter, spread field without parameter, `Option` slot with several children, named slot on an intrinsic element |
| E0492 | a value of a type that cannot be used there (wrong child type in a slot, `bool` attribute without `presenceAttrs`, spread of a non-record, spread field or attribute of an unsupported type) |
| E0493 | static only: computed attribute (or spread field) of a `convert: None` rule (event handlers), computed `<script>` / `<style>` content |
| E0494 | malformed element: children of a void element, invalid tag or attribute name |
| E0495 | record literal or field assignment of a `@Sealed` type outside its module |
| E0200 / E0100 | syntax: mismatched closing tag, duplicate attribute / unterminated element, `}` or `>` in text |

## Testing

- `python3 tools/run_tests.py --suite next --filter ox` — conformance and error tests (including the `ox_widgets` and
  `ox_xml` providers and the provider error directories).
- `tools/test_std.sh tests/std/html_test.or`, `python3 tools/mutate_std.py --module html` — `std:html` and its `ox()`
  literal.
- `python3 tools/mutate_ox.py -j 2` — builds the compiler with each deliberate bug in the lexer, parser and checker and
  requires the OX tests to catch it.
- `python3 tools/bench.py --only html,html_hand --no-selfcompile` — the benchmark.
