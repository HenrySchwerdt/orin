# ADR-0044: OX — generic markup with typed attributes, slots and library providers

Status: proposed (2026-10-15). Implements the RFC "generic JSX with typed attributes and slots"
(`docs/proposals/generic-jsx-typed-slots.md`, PR #76) and decides its open questions. Supersedes the semantics part of
ADR-0043 (§2 "Semantics", §3 "Lowering" stay valid as the description of the `Markup` provider kind; the syntax of §1
stays). User guide: docs/ox.md.

## Context

ADR-0043 added JSX to Orin with semantics hard-wired to `std:html`: the checker knew the unit `$stdlib/html`, the `Html`
record, the HTML void and raw-text elements, URL and event attributes and the escape table. No other library could give
the same notation a meaning. The RFC asks for language-owned syntax with library-owned semantics: any library declares
which elements, attributes and slots exist, what they accept and what a markup expression evaluates to; `std:html`
becomes one such library and keeps its safety guarantees and its fused, allocation-poor output.

The project owner proposed the name **OX** for the notation (2026-10-15). Orin's constraints shape the design:

- no overloading, no optional record fields, no default arguments: a provider cannot declare "one attribute record with
  200 optional fields" (TypeScript's `IntrinsicElements`), and the compiler cannot pick a function by argument type;
- no compile-time evaluation of Orin code: static text can only be escaped at compile time if the compiler can apply
  the provider's rule without running Orin;
- top-level constants are scalar literals only (`check/decls.or`).

## Decision

### 1. Name

The markup notation is **OX**. Internals follow (`EOx`, `OxElement`, `check/ox.or`, token kinds `KOxOpen` ..., error
codes stay E0490-E0495). React / TypeScript JSX remains the reference for the syntax.

### 2. Syntax

Unchanged from ADR-0043 §1 (elements, fragments, attributes `name="s"` / `name={e}` / bare `name`, text rules, `{expr}`
children, the `<` rule), plus:

| Form | Meaning |
|---|---|
| `import ox from "module";` | selects the file's **OX provider** (§3). At most one per file; it binds no name. |
| `<Card {...props} title="x" />` | **spread**: every field of the record `props` is an attribute. On a component it fills parameters (§4.1); on an intrinsic element of a `Markup` provider it expands statically (§4.3). |
| `<Dialog><:header>..</:header>..</Dialog>` | **named slot** `header`: its children fill the component's parameter `header`. Only directly inside a component or member tag. `</:header>` must repeat the name. |
| `<ui.Card title="x">..</ui.Card>` | **member tag**: the tag is a dotted path whose last segment starts upper-case; the call of the method `Card` of the value `ui`, or of the static method `Card` when `ui` names a class (§4.5). The closing tag repeats the whole path. |
| `@Sealed type T = { .. };` | record literals of `T` and assignments to its fields are only allowed in the declaring module (E0495). |

Why `<:name>` for named slots: `<slot name="..">` is a real HTML element (Web Components) and would make the
notation ambiguous for exactly the provider it must serve; `slot="name"` attributes (Astro, old Vue) put a slot
marker on an element and need a wrapper for text; `<template #name>` (Vue) needs a new attribute syntax. `<:name>` is
not valid HTML or XML, so no provider can mean anything else by it, it is short, and the parser recognises it at `<:`.

A tag is a path `p1.p2. .. .pn`: `p1` is an identifier or `this`, the others identifiers, and `pn` (the last) names what
is called. With `n > 1` and `pn` starting upper-case the tag is a member tag. A path with `n > 1` whose last segment is
lower-case is a syntax error, **E0200** (the nearest existing code for "this token is not allowed here"; E0494 is
reserved for names that are invalid by the notation's lexical rules, and `a.b` is a valid path that only lacks a
meaning). A closing tag that does not repeat the path is the existing mismatched-closing-tag error (E0200).

Not supported (syntax error or E0491): namespaced names `xlink:href`.

### 3. Providers

A file that contains markup must select a provider with `import ox from "M";` (else **E0490**, the message names
`import ox from "std:html";`). `M` is any module (std or user); it is resolved and loaded like any import. The provider
is **lexical and explicit**: each file names its own, there is no ambient default, and the compiler knows no library
by name.

`M` declares how it serves markup with an exported function `ox` whose body is a single `return` of a literal:

```ts
// std:html
export function ox(): Markup<Html> {
  return Markup<Html> {
    wrap: trustHtml, embed: render, embedAll: joinAll, text: escape, attr: escape,
    rules: [AttrRule { names: ["href", "src", "action", ...], prefix: "", convert: Some(escapeUrl) },
            AttrRule { names: [], prefix: "on", convert: None }],
    escapes: [Escape { char: "&", encoded: "&amp;" }, Escape { char: "<", encoded: "&lt;" }, ...],
    voidTags: ["area", "base", "br", ...], voidEnd: ">", rawTextTags: ["script", "style"], presenceAttrs: true,
  };
}
```

`ox()` is an ordinary, type-checked Orin function (so a provider author gets ordinary type errors), and it is never
called: the compiler reads the literal (string, bool, array and record literals, `Some(f)` / `None`, and names of
functions visible in `M`), resolves the function names in `M`, and calls those functions directly in the generated
code. Anything else in `ox()` is **E0490** ("the OX provider of `M` must return a literal"). A function rather than a
constant because top-level constants are scalar literals.

The protocol types live in the new module **`std:ox`** (types only, no code):

```ts
export type Escape = { char: string; encoded: string; };                  // one byte -> its encoding
export type AttrRule = { names: string[]; prefix: string; convert: Option<(value: string) => string>; };
export type Markup<R> = {
  wrap: (markup: string) => R;           // the finished text of a root -> the result value
  embed: (value: R) => string;           // an R child -> its text
  embedAll: (values: R[]) => string;     // an R[] child -> its text
  text: (value: string) => string;       // a computed string child -> its encoded text
  attr: (value: string) => string;       // a computed string attribute value -> its encoded text (unless a rule applies)
  rules: AttrRule[];                     // per-attribute overrides
  escapes: Escape[];                     // the encoding of static text and static attribute values, at compile time
  voidTags: string[];                    // elements without children and closing tag
  voidEnd: string;                       // how a void tag ends: ">" (HTML) or "/>" (XML)
  rawTextTags: string[];                 // elements whose children are static text only, written unencoded
  presenceAttrs: bool;                   // a `bool` attribute is present / absent (HTML) rather than an error
};
export type Components<R> = {
  fragment: (items: R[]) => R;           // several children where one R is expected; `<>..</>`
  text: (value: string) => R;            // text where an R is expected
};
```

There are two provider kinds, chosen by the literal's type:

- **`Markup<R>`**: the provider serialises markup to text. Intrinsic elements (lower-case tags) are written as text
  in one fused buffer (ADR-0043 §3, unchanged), the result is `wrap(buffer)`. All HTML knowledge that ADR-0043 had in
  the compiler is now data of `std:html`. The compiler knows only the XML family's surface (`<t a="v">..</t>`, quoted
  attribute values, `</` ending raw text).
- **`Components<R>`**: the provider builds values. An intrinsic tag `t` is the provider's exported function `t`, called
  like a component (§4.1). Text and multiple children become `R` through `text` and `fragment`.

Both kinds are generic over the result type `R`; the compiler requires nothing of `R` (no base class, no `Html`, no
node type).

### 4. Semantics

#### 4.1 Components (all providers)

An upper-case tag `C` names a function in scope (or a generic function). The element is a call of `C`:

- each attribute fills the parameter of the same name: `"s"` is a string literal, `{e}` the expression (checked
  against the parameter type, so `onClick={() => save()}` works where the parameter has a function type), a bare name
  `true`;
- a spread `{...r}` (a record) fills one parameter per field of `r`, `r` evaluated once; a field without a parameter is
  E0491; when an attribute and a spread name the same parameter, the one written later wins (TSX), both are evaluated;
- a parameter of type `Option<T>` may be left out and is `None`; every other missing parameter is E0491;
- the children fill the parameter `children` (the **default slot**), a `<:name>` slot the parameter `name`, both by
  the slot rule (§4.2); an attribute and a slot for the same parameter, two slots of one name, or a slot without a
  parameter are E0491;
- **evaluation order is source order**: when the attributes are written in another order than the parameters, the
  values are evaluated left to right into temporaries before the call; every value is evaluated exactly once;
- the result type is the function's return type; it is checked where the element is used, like any call. Contracts of
  `C` apply as to any call (it is one).

#### 4.2 Slots and fragments: typed by the expected type

The children of a slot, and the children of a fragment `<>..</>`, are checked against the **expected type** `T` (the
parameter type, or the type the context expects; with no expectation `T` is the provider's `R`). Whitespace-only text
is dropped (ADR-0043 text rules); `children` is the list of what remains:

| `T` | children | value |
|---|---|---|
| `R` of a `Markup` provider | any | the fused buffer of the children, `wrap(..)` |
| `R` of a `Components` provider | one child of type `R` | that child |
| `R` of a `Components` provider | otherwise | `fragment([c1, .., cn])`, each child converted to `R` (below) |
| `E[]` | any | `[c1, .., cn]`, each child converted to `E`; an `{x}` of type `E[]` is spliced in |
| `Option<E>` | none / one | `None` / `Some(c1)`; more is E0491 |
| `string` | text, strings, numbers | their concatenation (not encoded: it is a string, not markup) |
| any other | exactly one child of type `T` | that child (E0491 otherwise) |

A child is converted to `E`: an element is checked against `E`; text or a `string` child where `E` is `string` is the
string; text or a `string` where `E` is a `Components` provider's `R` is `text(s)`; a `Markup` provider's `R` child is
`wrap(text)` of the encoded text; anything else of the wrong type is E0492. A slot with no children is the empty
fragment of `T` (`[]`, `None`, `""`, `wrap("")`, `fragment([])`); for any other `T` it is a missing parameter (E0491).

This one rule replaces ADR-0043's "`children: Html`": lists, optional and single slots, heterogeneous slots through
union-typed elements, and lazy slots through function-typed parameters written as `{() => ..}` are all ordinary Orin
types.

#### 4.3 Intrinsic elements of a `Markup` provider

As ADR-0043 §2 / §3, with every HTML rule taken from the provider (`P` = the provider literal):

| Written | Text |
|---|---|
| `<t ..>kids</t>` | `<t` attributes `>` kids `</t>`; `t` in `P.voidTags`: `<t` attributes `P.voidEnd`, children E0494 |
| `a="s"`, `a={"s"}` | ` a="` + static encoding of `s` + `"` |
| `a={s}`, `s: string` | ` a="` + `conv(s)` + `"` where `conv` is the `convert` of the first rule matching `a`, else `P.attr`; a matching rule with `convert: None` makes a computed value **E0493** (static only) |
| `a={n}`, integer / float | ` a="` + decimal text + `"` (digits, sign, point, exponent: never encoded) |
| `a={b}`, `b: bool`; bare `a` | ` a` or nothing when `P.presenceAttrs`; E0492 otherwise |
| `a={o}`, `o: Option<T>` | `None`: nothing; `Some(v)`: as if written `a={v}`. One dynamic piece of the buffer (a match giving the whole ` a="..."` text or `""`). A `convert: None` rule rejects a computed `Option` too (E0493) |
| `{...r}` | `r` must have a record type (E0492); evaluated once into a temporary, then each field `f` in declaration order is the attribute `f={tmp.f}` at the spread's position (below) |
| `{s}` child, `s: string` | `P.text(s)` |
| `{h}` / `{hs}` child of type `R` / `R[]` | `P.embed(h)` / `P.embedAll(hs)` |
| `{n}` child, number | decimal text |
| text, `{"s"}`, `{c ? "a" : "b"}` | static encoding at compile time |
| children of `t` in `P.rawTextTags` | static text only, unencoded, must not contain `</`; anything computed is E0493 |
| named slot | E0491 (an intrinsic element has no parameters) |

A rule matches attribute `a` when `a` is in `names` or starts with a non-empty `prefix`, both compared ASCII
case-insensitively (HTML attribute names are case-insensitive: `HREF={u}` is a URL attribute, which ADR-0043 missed).
The static encoding replaces each byte listed in `P.escapes` by its `encoded` text.

**Spread.** The record type of `r` is known at compile time, so no reflection is needed: the spread expands statically
into the attributes `f={tmp.f}`, one per field, and everything above applies by field name (case-insensitive rule
matching included). A field named like a `convert: None` rule (`onclick`) is E0493, a URL field (`href`) goes through the
rule's `convert`, a `bool` field is a presence attribute (E0492 without `presenceAttrs`), numbers are decimal text, an
`Option<T>` field may be left out, and a field of any other type is E0492 naming the field. A spread therefore cannot
add an event handler or an unsanitised URL. When a name occurs more than once (written and spread, or in two spreads;
compared ASCII case-insensitively) the one written later wins in the output, as for components (§4.1); every value is
still evaluated exactly once, in source order, and the dropped ones are evaluated and discarded. Two attributes written
with the same name stay a syntax error.

Tag names start with a lower-case ASCII letter and continue with letters, digits, `-` and `_`; attribute names start
with a letter (E0494 otherwise). These are the notation's lexical rules, not HTML's.

#### 4.4 Intrinsic elements of a `Components` provider

`<t ..>..</t>` is a call of the provider module's exported function `t` with the component rules (§4.1), spread
included; no such function is E0491.

#### 4.5 Member tags

`<a.b.C attrs>kids</a.b.C>` is the call of the **method** `C` of the receiver `a.b`, with exactly the rules of §4.1 for
an upper-case function component: the method's parameters (without the receiver) give the attribute names; spread,
omitted `Option` parameters, the default slot `children`, `<:name>` slots and source-order evaluation are the same; the
result is the method's return type, checked where the element is used. The receiver is a class instance or an interface
value (a mutating method needs a receiver that is a mutable place, as for `a.b.C(..)`). Private methods follow the
method-call rules (E0405).

**Static methods.** `<T.C attrs>kids</T.C>`, where `T` is a single name that is no value in scope (no local, parameter
or global) and names a class (imported or local, generic or not), is the call of the static method `C` of `T`, with the
same component rules; the static method's parameters give the attribute names. This is the rule of `T.C(..)` itself, so
a value named `T` shadows the class for a tag exactly as for a call. Errors (E0491): `T` has no method `C`
(`` no static method `C` on class `T` ``), or `C` is an instance method (`` `T.C` is an instance method; a member tag on
a class name calls a static method ``); a private static method outside the class is E0405, as for the call. Inside a
class, `<T.C>` with `T` the class itself calls its own static method (`<this.C>` is the instance form).

**Modules are not receivers.** orin has no module values: an import binds the listed names, `import * as m` is a syntax
error (E0200), and `import ox from "M"` binds nothing. A member tag on a module therefore has nothing to name; a
component exported by a module is used as `<C>` after `import { C } from "M";`. Should namespace imports be added to
the language, `<m.C>` would be the call of `m`'s exported function `C` with the component rules; that is a change to
the module system (spec 04), not to OX.

The checker does not build a second call path: after the attributes are matched to parameters it checks the ordinary
method call `a.b.C(args)`, so visibility, mutation, generic classes and interface dispatch behave as in that call. The
receiver is a pure path (names, `this`, field reads), so reading it at the call is observably the same as evaluating it
before the attributes.

Errors, all **E0491** with the member written in the message: the member is not a method, e.g. a field of function type
(`` `ui.Card` is not a method; a member tag calls a method, whose parameters give the attribute names ``: a function type
has no parameter names to match attributes with); the receiver's type has no method of that name; and every error of
§4.1 (unknown attribute, missing parameter, ...).

### 5. std:html as a provider

`std:html` keeps its API and adds `export function ox(): Markup<Html>` with the rules of ADR-0043 as data. `Html` is
`@Sealed`. `trustHtml`, `render` and `joinAll` become the provider's `wrap`, `embed` and `embedAll` and are `@Inline`,
so the generated code is the same as ADR-0043's (a record built around the buffer, a field read per child).
`tests/next/run/ox_escape_diff.or` keeps comparing the compile-time encoding (now read from `std:html`'s `escapes`)
with `std:html.escape` on all 256 byte values.

Migration: a program with markup adds `import ox from "std:html";` next to its other imports.

### 6. Conformance: two more providers

- `tests/next/run/ox_widgets/`: a `Components<Widget>` provider (a widget tree, not text) with typed attributes,
  function-valued `onClick` props, `Option` attributes, a default slot of type `Widget[]`, required and optional named
  slots, a `string` slot, intrinsic lower-case tags as provider functions, and evaluation-order checks. No compiler
  edits, no `std:html` import.
- `tests/next/run/ox_xml/`: a `Markup<Xml>` provider with a different escape table, `voidEnd: "/>"`, no presence
  attributes and its own static-only rule, showing that the serialising kind is not HTML-specific.

## Consequences

- The compiler no longer names any library: `check/ox.or` reads the provider literal; HTML lives in `stdlib/html.or`.
  A second library gets the notation without compiler changes (the acceptance criteria of the RFC).
- Performance of `std:html` markup is unchanged by construction (same fused lowering, calls to `@Inline` functions in
  place of a record literal and a field read); measured in docs/benchmarks.md "HTML rendering".
- The `Markup` kind encodes one choice: the provider is a serialiser of the XML family. A provider that wants another
  serialisation is a `Components` provider (any `R`, including strings built by its own functions).
- The provider literal is data the compiler interprets. Its type is checked by the normal checker, its shape by the
  compiler (E0490); a provider can still declare a wrong rule (e.g. a missing escape). `ox_escape_diff` is the pattern
  for testing a provider's static encoding against its runtime one.
- Breaking for ADR-0043 programs: they need `import ox from "std:html";`.

## Pre-sized buffer

A `Markup` root with at least one dynamic piece starts its concatenation from `str.withCapacity(hint)` (builtin
`BStrWithCapacity`, runtime `orin_str_with_capacity`, no surface method): `withCapacity(hint) + p0 + p1 + ..`. The empty
string is a fresh owned temporary, so the lowering appends every piece in place (`IStrAppend`), with no copy of the
first piece; the MIR of a root is one `builtin str.withCapacity(n)` followed by `strappend`s. The hint is the total byte
length of the static pieces plus 16 bytes per dynamic piece (`OX_DYN_ESTIMATE` in `check/ox.or`; 32 was measured and
gains nothing but memory). The runtime clamps it to 1 MiB (`ORIN_STR_HINT_MAX`). The hint never changes the value: a
dynamic piece larger than the estimate just grows the buffer as before. A root without a dynamic piece stays one literal.
Measured on `bench/html`: `string_grows` 4.23 M -> 0.25 M, executed instructions 3.99 G -> 3.10 G (C backend), see
docs/benchmarks.md.

## Not done

- Namespaces; per-block provider selection. (Member tags on a class name, i.e. static methods, are done, §4.5; member
  tags on a module need namespace imports, which the language does not have, §4.5.)
- Generic slot parameters whose type is inferred from the children (a generic component's slot type must be fixed by
  its other arguments or written explicitly).
- The ADR-0043 performance follow-ups that remain (append without temporaries, component fusion, streaming). Pre-sized
  buffers are done (below).
