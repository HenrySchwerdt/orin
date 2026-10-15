# Proposal: generic JSX with typed attributes and slots

Status: **Proposed — design only, not implemented**

## Motivation

JSX is Orin language syntax, not an HTML or UI feature. PR #72 introduced useful parsing and secure HTML rendering, but its checker/lowering currently knows about `std:html`, `Html`, HTML tag rules, escaping, and HTML-specific diagnostics. This prevents independent JSX libraries from defining their own semantics.

Goal: preserve the ergonomic JSX notation while letting **any library** specify valid elements, attributes, slots, result types and runtime behavior using Orin's type system. `std:html` should be the first consumer of this generic facility, retaining its existing security guarantees and performance targets. No `std:ui` is proposed or required.

## Principles

1. **Language-owned syntax:** JSX elements, fragments, expressions, member tags, spread attributes and slot notation are parsed as first-class expressions.
2. **Library-owned semantics:** the compiler does not know HTML tag names, HTML event rules, URL schemes, DOM, widget trees, or a universal `Element` type.
3. **Typed attributes and slots:** component declarations or factory contracts specify accepted attributes, named slots, default slot, and result type. No universal `JSXChild` requirement.
4. **Explicit, lexical binding:** a JSX scope selects its provider explicitly; no implicit dependency on `std:html` or ambient magic `jsx` identifier. Exact declaration syntax remains to be decided.
5. **Normal Orin lowering:** JSX type-checks before lowering to typed function calls, so it participates in contracts, optimizations, and verification.
6. **Safety belongs to libraries:** `std:html` continues to seal `Html`, escape text/attributes contextually, sanitize dynamic URLs and reject unsafe dynamic event handlers and script/style content.
7. **No mandatory runtime tree:** libraries may build nodes, native widgets, strings, or other results.

## Proposed surface syntax (illustrative, not currently supported)

The exact syntax for declaring JSX providers and slots is subject to an RFC decision. The examples below express semantics, not a claim of current compiler support.

```tsx
// A library may expose a component contract:
type ColumnAttributes = { spacing?: int; alignment?: Alignment };
type ColumnSlots = { default: Widget[]; header?: Widget };
function Column(attributes: ColumnAttributes, slots: ColumnSlots): Widget { /* ... */ }

// In a scope bound to that library's JSX provider:
const view = <Column spacing={12}>
  <Text value="Hello" />
  <Button onClick={() => save()} />
</Column>;
```

The compiler checks `spacing` against `ColumnAttributes`, and each child against `ColumnSlots.default`. Unknown attributes and invalid child types are normal type errors. A function-valued `onClick` is valid **if and only if** the target component contract accepts it.

Named slots are similarly checked:

```tsx
type DialogSlots = {
  header: Widget;
  default: Widget[];
  footer?: Widget;
};

const dialog = <Dialog title="Settings">
  <slot name="header"><Heading value="Settings" /></slot>
  <Text value="Configure your application" />
  <slot name="footer"><Button text="Save" /></slot>
</Dialog>;
```

Here `<slot name="...">` is **candidate syntax** for a language-level named-slot expression; it must not be mistaken for the HTML `<slot>` element. Before implementation, decide whether an explicit alternative (for example a dedicated slot directive) avoids ambiguity and how it interacts with HTML custom elements.

## Semantics and type-checking requirements

- Intrinsic tags (e.g. `div`) are resolved through the selected provider's typed element registry/factory contract. Component tags (e.g. `Column`, `Dialog.Header`) resolve through normal names/member lookup.
- Attribute values are ordinary Orin expressions; spread attributes are type-checked for valid names and duplicate/override behavior. Preserve source evaluation order and evaluate expressions exactly once.
- The default slot is an ordered sequence, but its accepted type is provider/component-defined; single-value, optional, heterogeneous and lazily evaluated slots must be expressible through normal Orin types/functions.
- Named slots are checked for missing required slots, duplicates, unknown names, and incompatible contents. Distinguish slots from attributes without runtime reflection.
- Lists, conditionals, fragments, nullable/optional values and keys/refs are **not** intrinsically special: their validity and semantics come from provider contracts. Define how list flattening and fragments are delegated, rather than hardcoding HTML-like behavior.
- Components can return arbitrary types. The compiler must not require `Html`, `Widget`, `VNode`, or a common base class.
- Contract checking occurs on resolved typed calls, preserving source spans and diagnostics for the original JSX.
- Any optimization of JSX must preserve observable evaluation order, exception/trap behavior, ownership/borrows, and contract semantics.

## Lowering model

Conceptually, after type checking:

```tsx
<Column spacing={12}><Text value="Hello" /></Column>
```

becomes a typed construction call equivalent to:

```text
Column(
  attributes = ColumnAttributes { spacing: 12 },
  slots = ColumnSlots {
    default: [Text(attributes = TextAttributes { value: "Hello" }, slots = ...)]
  }
)
```

This is a semantic sketch, **not** a requirement that all components use exactly two positional arguments or allocate arrays. A provider contract may map JSX to functions/builders and may represent slots lazily. Lowering should not force intermediate nodes or buffers.

## std:html migration and security invariants

Refactor `std:html` into an ordinary provider of typed intrinsic tags and component construction. Move the HTML-specific rules currently in the compiler checker (notably `compiler/check/jsx.or`) to the library or library-defined contracts:

- Safe HTML value construction: keep `Html` sealed; dynamic strings are escaped in their output context.
- Attribute typing and context: URL attributes use URL sanitization and HTML escaping; event-handler attributes reject dynamic executable values; script/style dynamic content is prohibited unless a separately reviewed safe mechanism exists.
- Static literals must also be treated according to their HTML context. Do not regress the security of literal `href`, `script`, `style` or raw markup.
- Maintain the explicit, auditable `trustHtml` escape hatch.
- Preserve `document`, `render`, fragments, component calls and array children, subject to the generic slot model.
- Existing JSX HTML tests, differential escaping tests and mutation tests remain mandatory.
- Maintain or recover fused string-building performance through ordinary inlining/escape analysis/string fusion, not HTML-only JSX lowering. Benchmark against PR #72 before accepting performance regressions.

**Open design risk:** merely typing attributes as `string` cannot enforce contextual HTML safety. The HTML provider needs a robust way to distinguish URL, text, quoted attribute, raw-text and trusted-HTML contexts without compiler-side HTML knowledge. Design and test this explicitly before deleting the existing safeguards.

## Implementation sequence

1. Write the JSX provider/typed slot RFC and decide exact syntax, intrinsic-tag resolution, fragments, named-slot disambiguation, generics, optional/lazy slots and spread semantics.
2. Keep the existing JSX parser but separate generic syntax/HIR from HTML-specific checking and string fusion.
3. Add a generic typed JSX resolution and lowering path with diagnostics and source spans.
4. Build a minimal **external** fixture provider with function-valued props, typed default/named slots, member components and a non-HTML result type. This is a conformance test, not a standard UI package.
5. Port `std:html` to the same mechanism; retain sealed values and contextual escaping/sanitization guarantees.
6. Run all existing JSX, std:html, compiler self-hosting, C/LLVM differential and mutation suites; add invalid-prop/slot and evaluation-order tests.
7. Benchmark allocations, instruction counts and output against the current fused implementation. Optimize generic calls if necessary.

## Acceptance criteria

- The compiler accepts JSX without importing `std:html` when another explicit provider is in scope.
- A second, independent library can implement JSX with typed attributes, named/default slots and arbitrary result type, without compiler edits.
- `std:html` uses the same generic JSX mechanism, not a separate hard-coded JSX path.
- A UI provider can accept function-valued event props while `std:html` rejects its unsafe HTML counterparts through its own contracts.
- Invalid/missing/duplicate attributes and slots yield useful compile-time diagnostics.
- No compulsory virtual DOM, universal node type or `std:ui` package.
- Existing HTML safety tests continue to pass; performance changes are measured and documented.

## Non-goals

- Implementing React, state management, reconciliation or a platform renderer in the compiler.
- Requiring a new standard UI module.
- Automatically treating `key` and `ref` as special language semantics.
- Shipping the proposed API without resolving the open design questions.
