# Known limitations
- Orin-B only (see bootstrap-subset.md): no classes, closures, floats, annotations. The
  self-hosted compiler additionally accepts simple generics (ADR-0007: no bounds, no generic
  methods, no default type arguments; instantiation depth limit 32, E0413).
- Memory safety is not formally established; see architecture.md "Safety status".
- Stage 0 stores string literals as Rust `String`: `\xHH` escapes ≥ 0x80 that are not valid UTF-8
  become U+FFFD under Stage 0 (the self-hosted compiler keeps raw bytes).
- Early exits from inside expressions (`?`, diverging match arms) may leak temporaries (safe, not
  freed). Records/variants are limited to 64 slots.
- No hash maps in Orin-B; compiler symbol tables use linear search.
