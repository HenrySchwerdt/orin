# 01 — Syntax and Grammar

## Goals

Orin source MUST look familiar to a TypeScript reader, be deterministic to parse/format, and expose one canonical construction per common operation. The compiler formatter is the canonical spelling authority. Source files use `.or`, UTF-8, `{}` blocks and `;`-terminated statements. Comments: `//` and `/* ... */`. Identifiers are case-sensitive. `var` is a syntax error.

## Core examples

```typescript
const name = "Alice";
let counter: int = 0;
counter += 1;

function double(n: int): int {
  return n * 2;
}

type User = { id: int; name: string; };
const user = User { id: 42, name: "Alice" };
const renamed = User { ...user, name: "Bob" };

const names = users.filter(u => u.active).map(u => u.name);
```

`const` and `let` MUST be initialized. `const` bindings cannot be assigned again. `let` permits reassignment. No JS hoisting, `var`, dynamic property creation or implicit `this` rebinding. Prefer postfix `?` for `Result` propagation and `match` for tagged unions; an exhaustive pattern check is mandatory.

## Bootstrap EBNF (syntax sketch, not full lexical specification)

```ebnf
program       = { declaration } ;
declaration   = importDecl | exportDecl | functionDecl | typeDecl
              | enumDecl | classDecl | interfaceDecl | annotationDecl ;
importDecl    = "import", ("{", importNames, "}" | "*", "as", identifier), "from", string, ";" ;
importNames   = importName, {",", importName}, [","] ;
importName    = identifier, ["as", identifier] ;
exportDecl    = "export", (functionDecl | typeDecl | enumDecl | classDecl
              | interfaceDecl | reexportDecl) ;
reexportDecl  = "{", importNames, "}", "from", string, ";" ;
functionDecl  = {annotationUse}, "function", identifier, [typeParams],
              "(", [params], ")", [":", type], block ;
params        = param, {",", param} ;
param         = identifier, ":", type ;
typeParams    = "<", identifier, {",", identifier}, ">" ;
typeDecl      = {annotationUse}, "type", identifier, [typeParams], "=", type, ";" ;
type          = unionType ;
unionType     = postfixType, {"|", postfixType} ;
postfixType   = primaryType, {"[]"} ;
primaryType   = identifier, ["<", type, {",", type}, ">"]
              | "{", {field}, "}" | "(", type, ")" ;
field         = identifier, ":", type, ";" ;
enumDecl      = {annotationUse}, "enum", identifier, "{", variants, "}" ;
classDecl     = {annotationUse}, "class", identifier, "{", {classMember}, "}" ;
classMember   = {annotationUse}, constructorDecl | methodDecl | fieldDecl ;
interfaceDecl = "interface", identifier, [typeParams], "{", {signature}, "}" ;
annotationUse = "@", identifier, ["(", [arguments], ")"] ;
block         = "{", {statement}, "}" ;
statement     = variableDecl | assignment, ";" | returnStmt | ifStmt
              | whileStmt | forStmt | expression, ";" | block ;
variableDecl  = ("const" | "let"), identifier, [":", type], "=", expr, ";" ;
assignment    = lvalue, ("=" | "+=" | "-=" | "*=" | "/="), expr ;
returnStmt    = "return", [expr], ";" ;
ifStmt        = "if", "(", expr, ")", block, ["else", (block | ifStmt)] ;
whileStmt     = "while", "(", expr, ")", block ;
forStmt       = "for", "(", "const", identifier, "of", expr, ")", block ;
expr          = conditionalExpr ;
conditionalExpr = logicalOr, ["?", expr, ":", expr] ;
logicalOr     = logicalAnd, {"||", logicalAnd} ;
logicalAnd    = equality, {"&&", equality} ;
equality      = comparison, {("==" | "!="), comparison} ;
comparison    = additive, {("<" | "<=" | ">" | ">="), additive} ;
additive      = multiplicative, {("+" | "-"), multiplicative} ;
multiplicative = unary, {("*" | "/" | "%"), unary} ;
unary         = ["!" | "-"], postfix ;
postfix       = primary, {call | member | index | errorPropagate} ;
call          = "(", [arguments], ")" ;
member        = ".", identifier ;
index         = "[", expr, "]" ;
errorPropagate = "?" ;
primary       = identifier | literal | arrayLiteral | recordLiteral
              | lambda | matchExpr | "(", expr, ")" ;
lambda        = identifier, "=>", expr | "(", [params], ")", "=>", expr ;
matchExpr     = "match", "(", expr, ")", "{", {pattern, "=>", expr, [","]}, "}" ;
```

**Parser requirement:** The postfix `?` and conditional `?:` are distinct grammar contexts. The implementation MUST settle all ambiguity through the expression grammar; the illustrative EBNF is not sufficient alone. `enum` variants, annotation declarations, resource-safe closures and methods need dedicated productions as they graduate from the bootstrap subset. Parsing uses source spans. Generated class/annotation expansions are subject to normal typing.

## Canonical style

- Functions use `function`, no `fn` alternative.
- `const` when reassignment is unnecessary; `let` otherwise.
- One method of defining fallible values: `Result<T,E>` and postfix `?`.
- Single `match` expression for exhaustive tagged-union dispatch (no duplicate `switch` construct at launch).
- Record updates use `Type { ...value, changed: expression }`, NOT JavaScript spread of arbitrary objects.
- No arbitrary overloads or user-defined operators.

## Not decided

String interpolation, semicolon omission, generic method syntax, syntactic sugar for constructors, default arguments, and the complete annotated-class production remain OPEN. Until specified, do not add competing surface forms.
