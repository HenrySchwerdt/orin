# std:meta -- the processor interface (experimental, ADR-0046)

`import { Input, Output, fn, param, named, ret, call, fresh } from "std:meta";`

**Experimental** (the list in [stability.md](stability.md)). This is slice S3 of [ADR-0046](decisions/0046-typed-annotation-processors.md).
The module is pure data plus builders and a JSON codec; the compiler uses it for companion modules (S4) and runs processors written
against it (S5, S6), so it is in use today, but it is not frozen: names and shapes may change in any release until it is promoted.

It is pure: no grants, no I/O, no global state. The source is `library/std/metacore.or` (model and builders),
`library/std/metajson.or` (codec) and `library/std/meta.or` (re-exports both; import this one). `std:metacore` and
`std:metajson` can be imported directly. Tests: `tests/std/meta_test.or` (run by `tools/test_std.sh`).

## Input

`Input { modulePath, annotation, freshBase, decls: MDeclView[], types: MTypeShape[] }` is what a
`@Processor(A) function p(input: Input): Output` receives. `decls` are the declarations annotated with `A`, in source
order. Every item carries an `MRef` (an opaque id assigned by the compiler) that a diagnostic can point at.

| Type | Content |
|---|---|
| `MDeclView` | `kind` (`MKRecord`, `MKUnion`, `MKAlias`, `MKClass`, `MKInterface`, `MKFunction`, `MKConst`), `name`, `exported`, `typeParams`, `doc`, `annotations`, `contracts`, `fields`, `ctorParams`, `methods`, `variants`, `params`, `ty` (alias target / return type / const type) |
| `MFieldView` | `name`, `ty`, `exported`, `annotations` |
| `MMethodView` | `name`, `exported`, `typeParams`, `params`, `returns`, `doc`, `annotations`, `contracts` |
| `MAnnotation` | `source` (declaring module), `name`, `args: MArg[]` (one per annotation field in order; an omitted trailing `Option` is `MCNone`) |
| `MConst` | `MCBool`, `MCInt`, `MCFloat(text)`, `MCString`, `MCTag(variant)`, `MCArray`, `MCNone`, `MCSome` |
| `MContract` | `kind` (`MRequires` ... `MRule`) and the clause as read-only text |
| `MType` | `MNamed(name, args)`, `MArray`, `MOption`, `MResult`, `MFn(params, ret)`, `MUnion(variants)` |
| `MTypeShape` | a named type that occurs, listed once: `MSRecord`, `MSUnion`, `MSAlias`, `MSOpaque` |

Helpers: `annotationArg`, `findAnnotation`, `constString`, `constInt`, `constBool`, `ref`, `emptyInput`.

## Output

`Output { imports: MImport[], decls: MDecl[], diagnostics: MDiagnostic[] }`.

* `MDecl`: `MDFn`, `MDConst`, `MDRecord`, `MDUnion`, `MDClass` (no inheritance). All have an `exported` flag (default
  private) and a `doc`.
* `MStmt`: `MSConst`, `MSLet`, `MSAssign`, `MSReturn`, `MSExpr`, `MSIf`, `MSWhile`, `MSForOf`, `MSMatch`.
* `MExpr`: literals (`MEInt`, `MEFloat`, `MEString`, `MEBool`), `MEName`, `MECall`, `MEMethod`, `MEField`, `MEIndex`,
  `MERecord`, `MEArray`, `MEUnary`, `MEBinary`, `MEMatch`, `METry` (`?`), `MECond` (`c ? a : b`).
* `MPattern`: `MPWild`, `MPBind`, `MPVariant(name, subs)` (also `Some`/`Ok`/`Err`/`None`/tags), `MPLit`.
* `MDiagnostic { severity: MError | MWarning, message, at: MRef }`: the position is always a ref copied from the input.

Builders are small functions; a function declaration looks like

```ts
import { fn, param, named, ret, call, name, exportDecl, nameGen, output } from "std:meta";

@Processor(Json)
export function jsonCodecs(input: Input): Output {
  let g = nameGen(input.freshBase);
  const tmp = g.fresh("tmp");                                   // "__g4000_tmp"
  const enc = fn("encodeUser", [param("u", named("User"))], named("Json"), [ret(call("encode", [name("u")]))]);
  return output([exportDecl(enc, true)]);
}
```

Declaration builders: `fn`, `constant`, `recordType`, `unionType`, `classType` (with `classField`, `ctor`, `methodDecl`);
changers: `exportDecl(d, flag)`, `withTypeParams`, `withDoc`. Statements: `constS`, `constT`, `letS`, `letT`, `assign`, `ret`,
`retVoid`, `exprS`, `ifS`, `whileS`, `forOf`, `matchS`. Expressions: `intLit`, `floatLit`, `str`, `boolLit`, `name`, `call`,
`callExpr`, `callGeneric`, `method`, `dot`, `index`, `record`/`initField`, `arrayLit`, `unary`, `binary` and the shortcuts
`neg not add sub mul div rem eq ne lt le gt ge andAlso orElse`, `tryOp`, `cond`, `matchExpr`/`arm`/`armStmts`. Types:
`named`, `generic`, `arrayOf`, `optionOf`, `resultOf`, `fnOf`, `unionOf`, `variant`, `param`. Output:
`output`, `emptyOutput`, `withImports`, `withDiagnostics`, `importFrom`, `diagError`, `diagWarning`, `hasErrors`.

## Hygiene

`fresh(name, n)` returns `__g<n>_<name>` and is a pure function. A processor either passes its own counter or uses
`let g = nameGen(input.freshBase); g.fresh("tmp")`, which returns `__g<base>_tmp`, `__g<base+1>_tmp`, ... There is no
global counter. The compiler gives every processor run a distinct `freshBase`, so two processors writing into the same
companion module never produce the same helper name. `__g` names are reserved for generated code (ADR-0046, E0447).

## JSON encoding

`encodeInput(i): string`, `decodeInput(text): Result<Input, string>`, `encodeOutput(o): string`,
`decodeOutput(text): Result<Output, string>`, plus `inputToJson`/`inputFromJson`/`outputToJson`/`outputFromJson` on
`std:json` values.

* **Stable and deterministic:** compact `std:json` text, keys in a fixed order, tagged unions as `{"k": kind, ...}`,
  no timings or paths; equal values give equal bytes. The envelope is
  `{"format":"orin.meta.input"|"orin.meta.output","version":1,...}`.
* **Strict and total:** wrong format or version, missing keys, wrong value kinds, unknown tags/operators and nesting
  deeper than the `std:json` limit (200) give `Err("<path>: <problem>")`, e.g.
  `.types[0].shape.ty: unknown type kind "bogus"`. Never a trap. Key order and unknown extra keys on input are accepted.
* **Integers only** (the `std:json` limit): float constants and literals are carried as their source text (`MCFloat`,
  `MEFloat`).

## Not here

The compiler runs processors since S5: it builds the processor into a helper executable whose generated `main` calls
`decodeInput` / `encodeOutput` of this module (docs/annotation-processors.md), or consumes a recorded `Output` (S4 test hook);
`orin expand` prints the generated code through the formatter. No validation that a built tree
type-checks: generated code is checked like hand-written code by the compiler.
