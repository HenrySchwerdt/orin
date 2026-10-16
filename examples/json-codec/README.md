# json-codec: `@Json` codecs generated at compile time (ADR-0046 S6)

An example of a user-defined annotation with a processor. It is **not** part of the compiler or of `std` (owner decision
2026-10-16): the annotation, the processor and the runtime support are ordinary Orin code in `lib/`, the program that uses them is
in `app/`.

```
lib/orin.toml, lib/src/module.or   @Annotation(type) Json, @Annotation(field) JsonName, @Processor(Json) jsonCodecs
lib/src/runtime.or                 what the generated code calls (re-exported by module.or: a dependency exposes only its root)
app/orin.toml                      dependency json-codec = { path = "../lib" }, [annotations] processors = ["json-codec"]
app/src/models.or                  @Json records (User, Address); app/src/main.or imports "./models.gen"
app/expected.expand.txt            golden of `orin expand` (the generated companion)
app/expected.out                   golden output of the program (identical on the C and LLVM backends)
```

```ts
@Json
export type User = { id: int; @JsonName("display_name") name: string; tags: string[]; nick: Option<string>; address: Address; };
// generated into ./models.gen:
//   export function encodeUser(v: User): JsonValue
//   export function decodeUser(j: JsonValue): Result<User, string>
//   export function decodeUserAt(j: JsonValue, path: string): Result<User, string>
```

`JsonValue` is `Json` of `std:json`; it has another name here because `Json` is the annotation. Decode errors carry a path:
`$.address.zip: expected an int, found a string`, `$: missing field "display_name"`, `$.tags[1]: expected a string, found an int`.

Run it (from the repository root, with a built compiler):

```sh
build/bootstrap/orin2 expand examples/json-codec/app          # review the generated code
orin run examples/json-codec/app
```

## Supported field types

`int`, `bool`, `string`, `T[]` and `Option<T>` of supported types, and records annotated `@Json` **declared in the same module**.
An absent or `null` `Option` field decodes to `None` and encodes to `null`. Everything else is a processor diagnostic at the field
(E0522), for example `float` (`std:json` has integers only), a union, a record without `@Json`, `Option<Option<T>>`, a generic type or a
repeated JSON key; see `tests/processors/json_bad`.

Limits of this example, not of the feature: a companion module cannot import another companion (one round of expansion, E0520),
so a `@Json` record in another module cannot be nested; the processor does not know which records of other modules carry `@Json`,
so it rejects them. Unions and classes are not supported.

## Cost at compile time

Measured on the CI-class sandbox (4 runs of `orin compile app/src/main.or` to C, `-O` of the C compiler not included), program of
this directory: 2 records, 8 fields, 160 lines of generated code.

| build | time |
|---|---|
| no processor (the generated code pasted into `models.or`) | 0.06 s |
| processor, warm cache (`.orin/processors` has the output) | 0.08-0.11 s |
| processor, cold cache (build the helper with `cc -O1`, run it, convert) | 2.87 s (2.86-2.88) |

So generation costs about 0.02-0.05 s per build once cached and about 2.8 s the first time per processor (the helper executable is
built with the C compiler; later changes of the annotated module reuse the helper and only re-run it). The C output has the same size
(222,271 bytes with the processor, 221,849 bytes with the code pasted in; the difference is the helper names). See
docs/annotation-processors.md for the cache.

# Related example

`examples/routes`: `@Route("/users/:id", Get)` on methods generates `routeTable()` and a matcher `matchRoute(verb, path)`. It is a single
package (the processor runs because it belongs to the package itself).
