- **Clearer first-day diagnostics.** E0402 no longer mentions "Orin-B"; E0405 on `string` lists the methods that exist
  and explains that `length` is a property; E0300 for an unresolved name suggests `this.<field>`, `new C(...)` or the
  std module replacing a JavaScript global; E0300 for `number`, `any`, `boolean` and `Promise` suggests the Orin type;
  E0400 for a returned value in a `void` function suggests declaring the result type. Message text and notes only.
