# ADR-0005: Orin-B built-in library surface and loop control

Status: accepted (2026-10-13)

- `break`/`continue` are added (absent from the spec-01 EBNF sketch, standard TS, no competing form).
- `array.length` and indices are `usize` as spec 02 requires; conversions are explicit and
  checked: `int.toUsize()`, `usize.toInt()`.
- `xs.push(v)` / `xs.pop()` are allowed only on `let` places. Under value semantics they behave
  as `xs = xs.with(v)`: no alias observes the change, so this is not the "hidden shared mutable"
  JS method spec 08 forbids. Unique arrays are updated in place (amortised O(1)).
- Fallible std functions in Orin-B use `string` as the error type (`Result<string, string>`)
  until std error types (e.g. `FileError`) are designed. `Result<void, E>` uses `Ok()`.
- I/O: `console.log`/`console.error` (JS-familiar), `std:fs`, `std:process`.
