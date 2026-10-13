# ADR-0003: Postfix `?` vs conditional `?:`

Status: accepted (2026-10-13)

Spec 01 requires the grammar to settle the ambiguity. Rule: after a postfix expression, `?` is
error propagation iff the next token cannot begin an expression — i.e. it is one of
`) ] } , ; . ? :` or end of file. Otherwise it begins a conditional. Hence `f()?.x`,
`g(a?, b)`, `return r?;` propagate; `c ? 1 : 2` is a conditional. A propagation followed by a
binary operator (`a? + 1`) is not supported; write `(a?) + 1`.
