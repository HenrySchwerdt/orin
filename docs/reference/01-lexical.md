# 1. Lexical structure

Normative for the language as implemented by `compiler/syntax/lexer.or` (the tokens) and
`compiler/syntax/parser.or` (the contextual words). Conventions of this reference are in the
[README](README.md): a rule has an id, a statement, and the tests that exercise it.

## 1.1 Source text

**LEX-1.** A source file is UTF-8 text with the extension `.or`. Outside string literals, template
literals, OX text and comments only ASCII characters may appear; any other character is the lexical
error E0100 ("unexpected non-ASCII character"). Inside a string or comment, bytes pass through unchanged.
- Tests: `tests/parse_edge/err0100_bad_char_nonascii.or`, `tests/parse_edge/err0100_bad_char_emoji.or`,
  `tests/parse_edge/ok_unicode_comment.or`, `tests/next/run/std_utf8_basic.or`.

**LEX-2.** White space is space, tab, LF and CR. It separates tokens and is otherwise insignificant
(CRLF files are accepted). Any other control character (form feed, vertical tab, NUL) is E0100.
- Tests: `tests/parse_edge/ok_crlf.or`, `tests/parse_edge/ok_tabs.or`,
  `tests/parse_edge/err0100_bad_char_formfeed.or`, `tests/parse_edge/err0100_bad_char_vtab.or`,
  `tests/parse_edge/err0100_bad_char_nul.or`.

**LEX-3.** A character that starts no token (`#`, `$`, `~`, `^`, `\`, a single quote, a lone `@`, `&` not
doubled outside a type-parameter list, ...) is E0100 ("unexpected character"). The lexer stops at the first lexical
error; it reports exactly one.
- Tests: `tests/errors/e0100_bad_char.or`, `tests/parse_edge/err0100_bad_char_hash.or`,
  `tests/parse_edge/err0100_bad_char_dollar.or`, `tests/parse_edge/err0100_bad_char_tilde.or`,
  `tests/parse_edge/err0100_bad_char_caret.or`, `tests/parse_edge/err0100_bad_char_quote.or`,
  `tests/parse_edge/err0100_bad_char_at.or`, `tests/parse_edge/err0100_bad_char_backslash.or`.

## 1.2 Comments

**LEX-4.** `//` starts a comment that runs to the end of the line. `/* ... */` is a block comment; it may
span lines and does **not** nest (the first `*/` closes it). A comment is white space. An unterminated
block comment is E0100.
- Tests: `tests/parse_edge/ok_comments.or`, `tests/parse_edge/ok_only_comments.or`,
  `tests/errors/e0100_unterminated_comment.or`, `tests/parse_edge/err0100_bad_comment_unterminated.or`,
  `tests/parse_edge/err0200_comment_nested.or`.

There are no doc-comment tokens: `///` and `/** */` are ordinary comments to the lexer (tooling reads the
text, `compiler/analysis/doccomments.or`).

## 1.3 Identifiers

**LEX-5.** An identifier is `[A-Za-z_][A-Za-z0-9_]*` (ASCII only). Identifiers are case-sensitive. A
non-ASCII letter in a name is E0100.
- Tests: `tests/parse_edge/ok_idents.or`, `tests/parse_edge/err0100_bad_char_nonascii_ident.or`.

**LEX-6.** An identifier that starts with `__g` is reserved for generated code (annotation processors,
ADR-0046): using one in source is E0447.
- Tests: `tests/next/errors/e0447_generated_prefix.or`.

## 1.4 Keywords and reserved words

**LEX-7.** These words are keywords and can never be identifiers:

```
const let function return if else while for of break continue
type import export from match true false
```

Using one where an identifier is required is E0200.
- Tests: `tests/parse_edge/err0200_keyword_as_ident_match.or`, `tests/parse_edge/err0200_keyword_as_ident_from.or`,
  `tests/parse_edge/err0200_keyword_as_ident_of.or`, `tests/parse_edge/err0200_keyword_as_ident_type.or`,
  `tests/parse_edge/err0200_fn_name_keyword.or`, `tests/parse_edge/err0200_let_name_keyword.or`.

**LEX-8.** These words are reserved. They are lexed as keywords, so they can never be identifiers either.
Of them, `class`, `interface`, `new` and `this` have a meaning (declarations, object creation, the receiver);
`var` is rejected with its own code; the rest are reserved for future use and every use is E0200:

```
var class interface enum new this null undefined async await
```

`async` and `await` are reserved: Orin has no async functions; concurrency is `std:task` (chapter 8).
`enum` is reserved: tagged unions are written with `type` (chapter 3). `null` and `undefined` do not exist;
absence is `Option` (chapter 3).
- Tests: `tests/parse_edge/err0200_reserved_async.or`, `tests/parse_edge/err0200_reserved_await.or`,
  `tests/parse_edge/err0200_fn_async.or`, `tests/parse_edge/err0200_reserved_enum.or`,
  `tests/parse_edge/err0200_reserved_null.or`, `tests/parse_edge/err0200_reserved_undefined.or`,
  `tests/parse_edge/err0200_reserved_as_local.or`, `tests/parse_edge/err0200_reserved_as_type.or`,
  `tests/parse_edge/err0200_reserved_as_variant.or`, `tests/next/run/reserved_names_as_types.or`.

**LEX-9.** `var` is E0201 ("use `const` or `let`") wherever it occurs.
- Tests: `tests/errors/e0201_var.or`, `tests/parse_edge/err0201_var_stmt.or`, `tests/parse_edge/err0201_var_top.or`,
  `tests/parse_edge/err0201_var_param.or`.

**LEX-10.** Contextual words are ordinary identifiers that have a meaning only at one grammar position:
`extends` and `implements` (after a class or interface name, and `extends` in a type-parameter bound),
`public`, `private`, `static` (class member modifiers, and `public`/`private` on constructor parameters),
`constructor` (the class constructor), `ox` (the provider import, `import ox from "..."`), and the
target words of `@Annotation(...)` (`function method class type interface field const`). Elsewhere they may be
used as names.
- Tests: `tests/next/run/class_private_fields.or`, `tests/next/run/class_static_methods.or`,
  `tests/next/run/class_param_properties.or`, `tests/next/run/class_ctor_body.or`,
  `tests/next/run/iface_basic_dispatch.or`, `tests/next/run/ox_basic.or`, `tests/next/run/user_annotations`.

**LEX-11.** The names of the built-in types and functions (`int`, `string`, `Option`, `Some`, `console`, ...) and the names of the
built-in annotations and contract clauses (`Test`, `Inline`, `Rule`, ...) are not keywords. They live in the prelude scope
(chapter 6); a local value declaration may reuse them (`const int = 5;` is accepted), a type parameter may not reuse a built-in
type name (E0408), and the annotation names stay ordinary names outside `@Annotation` definitions.
- Tests: `tests/next/run/reserved_names_as_types.or`, `tests/next/errors/e0408_type_param_shadows_builtin.or`,
  `tests/run/std_prelude_edges.or`, `tests/next/errors/e0447_reserved_annotation_name.or`.

## 1.5 Integer literals

**LEX-12.** An integer literal is decimal digits (`123`) or `0x`/`0X` followed by hexadecimal digits
(`0x7F`). There is no `_` separator, no binary or octal form, no suffix. Leading zeros are decimal
(`007` is 7). A literal immediately followed by a letter or digit that does not belong to it, a `0x` without
digits, or `_` in a number is E0100 ("invalid character in number literal" / "hexadecimal literal has no digits").
- Tests: `tests/run/literals_hex.or`, `tests/parse_edge/ok_hex.or`, `tests/parse_edge/err0100_bad_int_underscore.or`,
  `tests/parse_edge/err0100_bad_int_binary.or`, `tests/parse_edge/err0100_bad_int_octal_o.or`,
  `tests/parse_edge/err0100_bad_int_suffix.or`, `tests/parse_edge/err0100_bad_int_hex_nodigits.or`,
  `tests/parse_edge/err0100_bad_int_alpha.or`.

**LEX-13.** The value of an integer literal is a non-negative number. Up to 2^63-1 it is an ordinary
literal; from 2^63 up to 2^64-1 it is a "big" literal that is valid only where the expected type is `u64` or
`usize` (E0430 elsewhere); above 2^64-1 it is E0100. A literal never has a sign: `-1` is the unary
operator applied to `1` (the checker accepts `-9223372036854775808` for `i64`).
- Tests: `tests/next/run/int_u64_full_range.or`, `tests/next/errors/e0100_int_literal_too_large.or`,
  `tests/next/errors/e0100_hex_literal_too_large.or`, `tests/next/errors/e0430_big_literal_as_int.or`,
  `tests/next/errors/e0430_big_literal_as_i32.or`, `tests/parse_edge/err0100_bad_int_overflow_u64.or`.

## 1.6 Float literals

**LEX-14.** A float literal is `digits . digits` with an optional exponent, or `digits` with an exponent;
the exponent is `e` or `E`, an optional `+`/`-`, and digits: `1.5`, `1e9`, `2.5e-3`, `1.5E+10`. A `.` after
digits begins a fraction only when a digit follows, so `1.toString()` is a member access on an integer. There is
no `.5`, no `1.`, no hexadecimal float, no `_`; `.5` is E0100 ("a float literal needs a digit before the decimal
point"). A literal whose magnitude exceeds about 1.8e308 is E0100. The token's text is canonicalised (`1e9` is `1.0e9`).
- Tests: `tests/next/run/float_literals_basic.or`, `tests/next/errors/e0100_float_leading_dot.or`,
  `tests/next/errors/e0100_float_hex.or`, `tests/next/errors/e0100_float_exponent_overflow.or`.

## 1.7 String literals

**LEX-15.** A string literal is delimited by double quotes and must end on the line it starts on. Its value is
the bytes between the quotes after escape processing. Escapes:
`\n` LF, `\t` tab, `\r` CR, `\0` NUL, `\\`, `\"`, `\'`, and `\xHH` (two hexadecimal digits, any byte value).
There is no `\u` escape. Any other escape, a malformed `\x`, a raw newline, or a missing closing quote is E0100.
Strings are byte strings: `"é".length` is 2.
- Tests: `tests/run/string_escapes.or`, `tests/parse_edge/ok_strings.or`, `tests/errors/e0100_bad_escape.or`,
  `tests/errors/e0100_unterminated_string.or`, `tests/parse_edge/err0100_bad_string_newline.or`,
  `tests/parse_edge/err0100_bad_string_escape_u.or`, `tests/parse_edge/err0100_bad_string_escape_x_half.or`,
  `tests/parse_edge/err0100_bad_string_escape_x_nonhex.or`, `tests/next/run/std_utf8_basic.or`.

## 1.8 Template literals

**LEX-16.** A template literal is delimited by backticks. `${` opens an interpolation holding any expression
and the matching `}` closes it (record-literal braces, arrow-function blocks, strings containing `}` and
nested templates inside the expression are handled; comments are allowed inside it). The text parts are
cooked: the escapes of strings plus `` \` `` and `\$`; a raw newline is part of the text (CRLF reads as LF); a `$` not
followed by `{` is literal. There is no `\u` escape and there are no tagged templates. An unterminated literal or
interpolation, or a bad escape, is E0100.
- Tests: `tests/next/run/template_lexing.or`, `tests/next/run/template_basic.or`,
  `tests/parse_edge/ok_template_nested.or`, `tests/next/errors/e0100_template_unterminated.or`,
  `tests/next/errors/e0100_template_unterminated_interpolation.or`, `tests/next/errors/e0100_template_bad_escape.or`.

## 1.9 Punctuation

**LEX-17.** The lexer takes the longest match among:

```
( ) { } [ ] , ; : . ? = + - * / % < > ! | &          (single)
== != <= >= += -= *= /= %= => && ||                  (double)
...  ==>                                              (triple)
@                                                     (only immediately before a letter)
```

`..` alone is E0100 ("did you mean `...`?"). `==>` is the contract implication (chapter 7). `|` appears
only in union declarations, `&` only in a rejected bound (`T extends A & B`, E0408); there are no bitwise
operators, shifts, `??`, `?.`, `**`, `++` or `--` in the language, and each is a syntax error.
- Tests: `tests/parse_edge/ok_ops_adjacent.or`, `tests/parse_edge/err0100_bad_dotdot.or`,
  `tests/parse_edge/err0200_binary_bitor.or`, `tests/parse_edge/err0200_binary_shift.or`,
  `tests/parse_edge/err0200_binary_coalesce.or`, `tests/parse_edge/err0200_incr.or`,
  `tests/parse_edge/err0200_assign_pow.or`, `tests/next/errors/e0408_multiple_bounds.or`.

## 1.10 Lexical modes of OX

**LEX-18.** Inside an OX element (chapter 9) the lexer switches modes. A `<` starts an element exactly when
it is followed by a letter, `>` (fragment), `/` (closing tag) or `:` plus a letter (named slot), **and** the previous token
cannot end an operand (so `a < b`, `f<T>(x)` and `Map<K, V>` stay comparisons and type arguments). Within a tag
names may contain `-`; attribute strings use `"` or `'` with no backslash escapes and decoded character
references; between tags the text is cooked by the React/TypeScript whitespace rule (entities decoded, lines
trimmed and joined). `}` and `>` are not allowed in OX text. An unterminated element is E0100.
- Tests: `tests/next/run/ox_lexer.or`, `tests/next/run/ox_basic.or`, `tests/next/run/ox_escape_diff.or`,
  `tests/next/errors/ox_unclosed.or`.

## Gaps: rules without a test

- LEX-11: no test shadows a built-in value or type name with a local declaration (`const int = 5;` is accepted by the compiler; checked by hand only).
- LEX-6 is tested for the user-visible prefix only (`e0447_generated_prefix`); the position (any identifier position) is not.
- LEX-3: no test for a lone `&` outside a bound, nor for a `|` in expression position (covered indirectly by `err0200_binary_bitor`).
- LEX-14: the 1.8e308 magnitude limit is tested only for the exponent form (`e0100_float_exponent_overflow`), not the 309-digit integer-part form.
- LEX-15: no test fixes that a non-ASCII byte inside a string is preserved bytewise except `std_utf8_basic` (library level).
