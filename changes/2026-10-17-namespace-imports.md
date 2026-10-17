- **Namespace imports and import aliases (ADR-0048 addendum).** `import * as bytes from "std:bytes";` binds a compile-time
  namespace (`bytes.fromString(..)`, `bytes.Bytes` in types, `bytes.f<T>(..)`, `m.Variant(x)` in patterns) and
  `import { empty as emptyBytes } from ".."` (also `export { a as b } from ..`) renames an import. A namespace is no value (E0400),
  a member the module lacks is E0300, and a local, parameter or declaration named like a namespace import is E0304. The generated
  code is identical to named imports. `import *` without `as` is a clear syntax error; the language server completes members
  after `ns.` for local modules.
