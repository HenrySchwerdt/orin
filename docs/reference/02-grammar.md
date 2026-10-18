# 2. Grammar

Normative for `compiler/syntax/parser.or` (recursive descent with precedence climbing over the table in
`compiler/syntax/precedence.or`). Notation: `a b` sequence, `a | b` alternative, `[a]` optional, `{a}` zero or more,
`'x'` a token, `NAME` a lexical class from [chapter 1](01-lexical.md), `(* ... *)` a comment. The grammar is
syntactic only: whether a program is accepted also depends on the checker (chapters 3 to 8).

The parser reports the first syntax error as E0200 (E0201 for `var`, E0408 for a construct the language
deliberately does not have, E0440/E0441/E0442/E0447 for annotations, ADR-0024/0046). With error recovery (the
default in `orin check` and the language server) it reports up to 20 errors per file, in source order; the
first one is always the error the non-recovering parse reports. The recovery points are a statement, a class or
interface member, and a top-level declaration.
- Tests: `tests/errors/e0200_missing_semicolon.or`, `tests/errors/e0200_unclosed_brace.or`,
  `tests/errors/e0200_missing_expression.or`, `tests/recovery/` (the error-recovery suite).

## 2.1 Module and items

```ebnf
module      = { item } EOF ;
item        = { decoration } ( import | reexport | declaration ) ;
import      = 'import' ( '{' [ names ] '}' | '*' 'as' IDENT | 'ox' ) 'from' STRING ';' ;     (* 'ox' = provider import, ADR-0043 *)
reexport    = 'export' '{' [ names ] '}' 'from' STRING ';' ;
names       = name { ',' name } [ ',' ] ;
name        = IDENT [ 'as' IDENT ] ;                                   (* alias: ADR-0048 addendum *)
declaration = [ 'export' ] ( function | typeDecl | constDecl | classDecl | interfaceDecl ) ;
```

**GRM-1.** Top-level code consists only of the declarations above; a statement at the top level is E0200.
Declaration order does not matter (functions and types may be mutually recursive).
- Tests: `tests/run/mutual_recursion.or`, `tests/parse_edge/err0200_stmt_at_top.or`, `tests/parse_edge/ok_items.or`,
  `tests/parse_edge/err0200_stray_semi_top.or`.

**GRM-2.** `import` and `export { ... } from` take a brace-enclosed name list (trailing comma allowed; each name may be
renamed, `a as b`) and a string path. `import` also has the namespace form `import * as m from "path";`; `import *`
without `as <name>` is E0200. There is no `import x from` and no default export. A file selects at most one OX
provider (`import ox from "..."`); a second one is E0200. (`as` is not a keyword: it is an identifier that has this meaning
only after an imported name or after `*`.)
- Tests: `tests/parse_edge/ok_import_namespace.or`, `tests/parse_edge/ok_import_alias.or`, `tests/parse_edge/ok_namespace_uses.or`,
  `tests/parse_edge/err0200_import_star_no_as.or`, `tests/parse_edge/err0200_import_star_no_name.or`,
  `tests/parse_edge/err0200_import_as_no_name.or`, `tests/parse_edge/err0200_import_as_twice.or`,
  `tests/parse_edge/err0200_import_star_with_names.or`, `tests/parse_edge/err0200_import_default_named.or`, `tests/parse_edge/err0200_import_no_from.or`,
  `tests/parse_edge/ok_reexport_export_forms.or`, `tests/parse_edge/err0200_reexport_no_from.or`,
  `tests/next/run/ox_basic.or`, `tests/next/errors/ox_no_provider.or`.

## 2.2 Declarations

```ebnf
function    = 'function' IDENT [ typeParams ] '(' [ params ] ')' [ ':' type ] block ;
params      = param { ',' param } [ ',' ] ;
param       = IDENT ':' type ;
typeParams  = '<' typeParam { ',' typeParam } '>' ;
typeParam   = IDENT [ 'extends' IDENT { '&' IDENT } ] ;  (* bounds: functions, classes and their methods; not on a type *)

typeDecl    = 'type' IDENT [ plainParams ] '=' typeBody ';' ;
plainParams = '<' IDENT { ',' IDENT } '>' ;
typeBody    = '{' { fieldDecl } '}'                    (* nominal record *)
            | variant { '|' variant }  (* tagged union: at least one 'Name(...)' or a '|' *)
            | type ;                                   (* transparent alias *)
fieldDecl   = { decoration } IDENT ':' type ';' ;
variant     = IDENT [ '(' type { ',' type } [ ',' ] ')' ] ;

constDecl   = 'const' IDENT [ ':' type ] '=' expr ';' ;

classDecl   = 'class' IDENT [ typeParams ] [ 'extends' IDENT ] [ 'implements' IDENT { ',' IDENT } ]
              '{' { member } '}' ;
member      = { decoration } ( field | method | constructor ) ;
field       = { modifier } IDENT ':' type [ '=' expr ] ';' ;
method      = { modifier } IDENT [ plainParams ] '(' [ params ] ')' [ ':' type ] block ;
constructor = 'constructor' '(' [ ctorParam { ',' ctorParam } ] ')' block ;
ctorParam   = [ 'public' | 'private' ] IDENT ':' type ;
modifier    = 'public' | 'private' | 'static' ;        (* contextual: only when another identifier follows *)

interfaceDecl = 'interface' IDENT [ plainParams ] [ 'extends' IDENT ] '{' { ifaceMethod } '}' ;
ifaceMethod = { decoration } IDENT '(' [ params ] ')' [ ':' type ] ';' ;
decoration  = contractClause | annotation ;           (* chapter 7 *)
```

**GRM-3.** A `type` declaration's right side decides its kind: `{` starts a record; a first member of the form
`Name(` or any `|` makes it a tagged union whose members must be `Name` or `Name(T, ...)` (a leading `|` is not
accepted); anything else is an alias. Record fields end with `;` and are separated by nothing else.
- Tests: `tests/run/record_basic.or`, `tests/run/union_basic.or`, `tests/next/run/closure_type_aliases.or`,
  `tests/parse_edge/ok_unions.or`, `tests/parse_edge/ok_records.or`, `tests/parse_edge/err0200_union_leading_pipe.or`,
  `tests/parse_edge/err0200_union_trailing_pipe.or`, `tests/parse_edge/err0200_union_empty_payload.or`,
  `tests/parse_edge/err0200_union_array_member.or`, `tests/parse_edge/err0200_record_semi_sep.or`,
  `tests/parse_edge/err0200_record_comma_sep.or`.

**GRM-4.** A function has a block body, an optional result type (omitted means `void`), and no default values, rest
parameters or overloads. A trailing comma is accepted in every comma-separated list (parameters, arguments, array
elements, record fields, variant payloads, name lists, match arms); a leading or doubled comma is E0200. A function has no
`function` expression form: nested `function` is E0200 (use an arrow function).
- Tests: `tests/parse_edge/err0200_fn_param_default.or`, `tests/parse_edge/err0200_fn_nested.or`,
  `tests/parse_edge/err0200_fn_expr.or`, `tests/parse_edge/err0200_fn_param_trailing_comma_ok_then_bad.or`, `tests/parse_edge/err0200_fn_no_body.or`,
  `tests/parse_edge/err0200_fn_param_leading_comma.or`, `tests/parse_edge/ok_return_forms.or`.

**GRM-5.** A type parameter takes a list of bounds joined with `&` (`T extends I`, `T extends Ord & Hash`); the list is written once, after
`extends`, and each bound is an identifier. A bound list is allowed on a generic function, on a generic class and on a generic method; on a
`type` it is E0408. The same bound twice in one list is E0304.
- Tests: `tests/next/run/multi_bounds_ord_hash.or`, `tests/next/run/multi_bounds_methods.or`, `tests/fmt/bounds.in.or`,
  `tests/next/errors/e0408_bound_on_generic_type.or`, `tests/next/errors/e0408_bound_on_type_alias_multi.or`,
  `tests/next/errors/e0304_duplicate_bound.or`, `tests/next/run/genclass_bounds.or`, `tests/next/run/iface_static_bound_sum.or`.

**GRM-6.** In a class body `public`, `private` and `static` are modifiers only when an identifier follows them (a field
or method may still be named `static`). A field has a type and an optional initialiser; a static field is E0408.
`constructor(...)` is recognised by its name without modifiers. Inheritance (`extends` on a class) parses but is E0408
in the checker; an interface may not have fields (E0408), bodies (E0408), generic methods (E0460, ADR-0040) or `extends` (E0408).
- Tests: `tests/next/run/class_private_fields.or`, `tests/next/run/class_static_methods.or`,
  `tests/next/run/class_param_properties.or`, `tests/next/errors/e0408_class_extends.or`,
  `tests/next/errors/e0408_interface_field.or`, `tests/next/errors/e0408_interface_default_method.or`,
  `tests/next/errors/e0408_interface_generic.or`, `tests/next/errors/e0408_interface_extends.or`.

## 2.3 Types

```ebnf
type      = name { '[' ']' }
          | '(' ( fnParams ')' '=>' type | type ')' { '[' ']' } ) ;
name      = IDENT [ '<' type { ',' type } '>' ] ;
fnParams  = [ IDENT ':' type { ',' IDENT ':' type } ] ;
```

**GRM-7.** A function type is `(name: T, ...) => R`; a `(` followed by `)` or by `name :` starts one, any other `(`
groups a type (`((x: int) => int)[]`). Parameter names in a function type are documentation. There is no union type
syntax (`A | B`), no tuple type and no `T?`; array types are `T[]`, nested as `T[][]`.
- Tests: `tests/next/run/closure_function_values.or`, `tests/next/run/closure_in_arrays.or`,
  `tests/parse_edge/ok_types.or`, `tests/run/array_nested.or`.

## 2.4 Statements

```ebnf
block   = '{' { stmt } '}' ;
stmt    = { loopClause } ( let | if | while | for | return | 'break' ';' | 'continue' ';' | block | exprStmt ) ;
let     = ( 'const' | 'let' ) IDENT [ ':' type ] '=' expr ';' ;
if      = 'if' '(' expr ')' block [ 'else' ( if | block ) ] ;
while   = 'while' '(' expr ')' block ;
for     = 'for' '(' 'const' IDENT 'of' expr ')' block ;
return  = 'return' [ expr ] ';' ;
exprStmt = expr [ assignOp expr ] ';' ;               (* a statement that is a 'match' expression needs no ';' *)
assignOp = '=' | '+=' | '-=' | '*=' | '/=' | '%=' ;
loopClause = contractClause ;                          (* before 'while' / 'for' only, chapter 7 *)
```

**GRM-8.** Conditions are parenthesised and bodies are blocks (no brace-less `if`). `else if` chains. There is no
`for (;;)`, `for ... in`, `do`/`while`, `switch`, label, `break`/`continue` with a value or label, or empty statement `;`.
`const`/`let` require an initialiser and bind one name (no destructuring); `var` is E0201.
- Tests: `tests/run/while_break_continue.or`, `tests/parse_edge/ok_for_forms.or`, `tests/parse_edge/ok_stmt_forms.or`,
  `tests/parse_edge/err0200_if_noparen.or`, `tests/parse_edge/err0200_if_nobody.or`, `tests/parse_edge/err0200_for_c_style.or`,
  `tests/parse_edge/err0200_for_in.or`, `tests/parse_edge/err0200_do_while.or`, `tests/parse_edge/err0200_switch.or`,
  `tests/parse_edge/err0200_break_label.or`, `tests/parse_edge/err0200_break_value.or`,
  `tests/parse_edge/err0200_stray_semi_stmt.or`, `tests/parse_edge/err0200_let_destructure.or`,
  `tests/parse_edge/err0200_let_noinit.or`.

**GRM-9.** Assignment is a statement, not an expression: `a = b = c;`, `if (x = 1)` and `f(x = 1)` are E0200. The
left side is parsed as an expression; whether it is a place is a checker rule (chapter 4).
- Tests: `tests/parse_edge/err0200_assign_chain.or`, `tests/parse_edge/err0200_assign_in_cond.or`,
  `tests/parse_edge/err0200_assign_in_expr.or`, `tests/parse_edge/ok_match_assign.or`.

## 2.5 Expressions

```ebnf
expr     = arrow | cond [ '==>' expr ] ;              (* '==>' only legal inside a contract, E0415 elsewhere *)
arrow    = ( IDENT | '(' [ arrowParam { ',' arrowParam } ] ')' [ ':' type ] ) '=>' ( block | expr ) ;
arrowParam = IDENT [ ':' type ] ;
cond     = bin0 [ '?' cond ':' cond ] ;
bin<n>   = bin<n+1> { op<n> bin<n+1> } ;              (* left associative, levels in the table below *)
unary    = ( '!' | '-' ) unary | postfix ;
postfix  = primary { '(' [ args ] ')' | '.' IDENT | '[' expr ']' | '?' } ;   (* '?' only as propagation, see GRM-12 *)
args     = expr { ',' expr } [ ',' ] ;
primary  = INT | BIGINT | FLOAT | STRING | template | 'true' | 'false'
         | IDENT | IDENT '<' type { ',' type } '>' ( '(' | recordBody )
         | IDENT recordBody
         | '(' expr ')' | '[' [ args ] ']'
         | 'match' '(' expr ')' '{' arms '}'
         | 'new' IDENT [ '<' type { ',' type } '>' ] '(' [ args ] ')'
         | 'this' | ox ;
recordBody = '{' [ '...' expr [ ',' ] ] [ IDENT ':' expr { ',' IDENT ':' expr } [ ',' ] ] '}' ;
template = TPL_FULL | TPL_HEAD expr { TPL_MID expr } TPL_TAIL ;
```

Binary operator table (`compiler/syntax/precedence.or`, `OpTable`), loosest first. All are left associative:

| Level | Operators | Notes |
|---|---|---|
| 0 | `\|\|` | short-circuit |
| 1 | `&&` | short-circuit |
| 2 | `==` `!=` | |
| 3 | `<` `<=` `>` `>=` | |
| 4 | `+` `-` | |
| 5 | `*` `/` `%` | |

Below level 0, in this order: the conditional `c ? a : b` (right associative), then `a ==> b` (right associative, its right side
a whole expression, contracts only). Tighter than level 5: unary `!` and `-`, then the postfix forms (call, `.`, index, `?`).

**GRM-10.** Operator precedence and associativity are exactly the table above: `a - b - c` is `(a - b) - c`, `a || b && c` is
`a || (b && c)`, `-a * b` is `(-a) * b`, `!a == b` is `(!a) == b`, `a < b == c < d` is `(a < b) == (c < d)`, comparisons
do not chain. There is no `**`, bitwise, shift, `??` or `?.` operator.
- Tests: `tests/run/arith_precedence.or`, `tests/run/bool_logic.or`, `tests/run/comparisons.or`,
  `tests/parse_edge/ok_prec_arith.or`, `tests/parse_edge/ok_prec_logic.or`, `tests/parse_edge/ok_prec_unary.or`,
  `tests/parse_edge/ok_prec_cond.or`, `tests/run/conditional_expr.or`, `tests/parse_edge/err0200_binary_triple_eq.or`.

**GRM-11.** `?:` is right associative (`a ? b : c ? d : e` is `a ? b : (c ? d : e)`), each branch is a `cond` (an arrow
function in a branch must be parenthesised), and it binds looser than every binary operator.
- Tests: `tests/run/conditional_expr.or`, `tests/parse_edge/ok_prec_cond.or`, `tests/parse_edge/err0200_cond_colon_only.or`,
  `tests/parse_edge/err0200_cond_nested_missing.or`.

**GRM-12.** A postfix `?` after an expression is error propagation exactly when the next token cannot begin an
expression, that is when it is one of `)` `]` `}` `,` `;` `.` `?` `:` or the end of the file (ADR-0003). Otherwise it
starts a conditional. Hence `f()?.x`, `g(a?, b)`, `return r?;` propagate and `c ? 1 : 2` is a conditional; `a? + 1` is not
supported, write `(a?) + 1`.
- Tests: `tests/run/question_vs_conditional.or`, `tests/parse_edge/ok_try_disamb.or`, `tests/parse_edge/ok_try_eof.or`,
  `tests/parse_edge/err0200_try_then_ident.or`, `tests/parse_edge/err0200_try_before_expr.or`,
  `tests/parse_edge/ok_optional_chain_like.or`, `tests/run/result_propagation.or`.

**GRM-13.** An arrow function starts where an expression starts and is recognised by lookahead: `name =>`, or a
parenthesised list (found by matching the parenthesis) followed by `=>` or by `: type =>`. Its body is a block when it starts with
`{` (so an arrow cannot return a record literal without parentheses), otherwise an expression. There are no `function`
expressions and no `async` arrows.
- Tests: `tests/next/run/closure_basic.or`, `tests/next/run/closure_void_and_zero_params.or`,
  `tests/next/run/closure_match_body.or`, `tests/parse_edge/err0200_fn_arrow.or`.

**GRM-14.** An identifier directly followed by `{` is a record literal (`Name { a: 1 }`), also with a spread first
(`Name { ...base, a: 2 }`, one spread, before the fields) and with type arguments (`Pair<int, string> { ... }`). In every
position that takes an expression followed by a block (`if`, `while`, `for`, `match`) the expression is parenthesised, so the
rule never meets a block. Shorthand fields, computed or string keys and methods in a record literal are E0200.
- Tests: `tests/run/record_basic.or`, `tests/run/record_update_spread.or`, `tests/parse_edge/ok_record_vs_block.or`,
  `tests/parse_edge/err0200_record_shorthand.or`, `tests/parse_edge/err0200_record_string_key.or`,
  `tests/parse_edge/err0200_record_spread_twice.or`, `tests/parse_edge/err0200_record_spread_second.or`,
  `tests/next/run/generic_pair.or`.

**GRM-15.** A `<` after an identifier is the start of explicit type arguments (`f<int>(x)`, `Pair<int, string> { ... }`) only
if a well-formed type list, `>` and then `(` or `{` follow; otherwise it is the less-than operator. This is decided by
backtracking, so `f(a < b, c > (d))` is a generic call (ADR-0007).
- Tests: `tests/next/run/generic_explicit_args.or`, `tests/parse_edge/ok_generic_close.or`,
  `tests/next/errors/e0400_explicit_type_args_arity.or`.

**GRM-16.** `new C(args)` and `new C<T>(args)` create a class instance or a `Map`; `this` is an expression inside a class.
`new` followed by anything but an identifier is E0200.
- Tests: `tests/next/run/class_stack.or`, `tests/next/run/map_basic_string_int.or`, `tests/next/run/genclass_basic.or`.

## 2.6 Match and patterns

```ebnf
arms    = { pattern '=>' ( block [ ',' ] | expr ',' ) } ;      (* the last expression arm may omit ',' before '}' *)
pattern = '_' | IDENT | IDENT '(' [ pattern { ',' pattern } ] ')'
        | INT | '-' INT | STRING | 'true' | 'false' ;
```

**GRM-17.** `match (e) { p => body, ... }` is an expression; as a statement it needs no `;`. An arm body is an expression
followed by `,` (the comma may be omitted before the closing brace) or a block (comma optional). A pattern is `_`, a name
(a binding, or a payload-free variant), a variant with sub-patterns, an integer (optionally negative), a string, or `true`/`false`.
Float, template, big-integer, record, array, or-patterns (`a | b`), guards, ranges and ident-paths are E0200.
- Tests: `tests/run/match_literals.or`, `tests/run/match_option_result.or`, `tests/parse_edge/ok_match_forms.or`,
  `tests/parse_edge/ok_match_stmt_noterm.or`, `tests/parse_edge/err0200_match_pattern_or.or`,
  `tests/parse_edge/err0200_match_pattern_guard.or`, `tests/parse_edge/err0200_match_pattern_record.or`,
  `tests/parse_edge/err0200_match_pattern_array.or`, `tests/next/errors/e0200_template_as_pattern.or`,
  `tests/next/errors/e0200_big_literal_as_pattern.or`, `tests/parse_edge/err0200_match_missing_comma.or`.

## 2.7 OX elements

```ebnf
ox       = '<' [ tag ] { attr } ( '/>' | '>' { oxChild } '</' [ tag ] '>' ) ;
tag      = IDENT { '.' IDENT } ;                                (* a dotted tag ends in an upper-case name *)
attr     = IDENT [ '=' ( STRING | '{' expr '}' ) ] | '{' '...' expr '}' ;
oxChild  = OXTEXT | '{' [ expr ] '}' | ox | slot ;
slot     = '<:' IDENT '>' { oxChild } '</:' IDENT '>' ;        (* directly inside a component only *)
```

**GRM-18.** The closing tag repeats the name; a fragment `<>` has no attributes and is not self-closing; attributes are unique
per element; a named slot `<:x>` is a child of a component (an element whose tag starts with an upper-case letter) only, has no
attributes and is not self-closing; `{}` is an empty expression child. Violations are E0200. Semantics are in chapter 9.
- Tests: `tests/next/run/ox_basic.or`, `tests/next/run/ox_components.or`, `tests/next/run/ox_member_tags.or`,
  `tests/next/errors/ox_mismatched_close.or`, `tests/next/errors/ox_duplicate_attr.or`, `tests/next/errors/ox_member_lowercase.or`,
  `tests/next/errors/ox_member_mismatched_close.or`, `tests/next/errors/ox_bad_tag.or`.

## Gaps: rules without a test

- GRM-4: no test shows a trailing comma accepted in a declaration parameter list (only the doubled comma is rejected, `err0200_fn_param_trailing_comma_ok_then_bad`); no test pins trailing commas in the other lists either (the formatter output, which uses them, is exercised by `tests/fmt/`).
- GRM-16: no parse-only test for `new` followed by a non-identifier.
- GRM-6: a field or method named `static` / `public` / `private` (the "only when an identifier follows" rule) has no test.
- GRM-2: the "one provider per file" rule has no test (only the missing provider, `ox_no_provider`).
