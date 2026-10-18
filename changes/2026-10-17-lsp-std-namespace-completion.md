- **LSP completion for std namespaces.** After `import * as bytes from "std:bytes";` the language server completes `bytes.` with the
  exported functions, types, classes, constants and union variants of the std module (also sub-directory modules such as
  `std:json/number` and flat `std:x/internal` files, and names a module re-exports), with the same signature details as for local
  modules; the member lists come from the embedded std sources and are kept in the analysis cache. Classes now appear in document
  symbols and completion too. The VS Code grammar highlights `as` in `import * as m from ".."` and `import { a as b }` as a keyword
  and `m` as a namespace.
