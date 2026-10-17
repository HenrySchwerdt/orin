# 9. A project with packages

A **package** is a directory with an `orin.toml`. It has modules, can depend on other packages, and carries its tests.

## The layout

```
09-project/
  orin.toml
  orin.lock
  src/
    main.or
    geometry/
      module.or
      rect.or
  tests/
    area_test.or
  banner/            a second package, used as a dependency
    orin.toml
    src/module.or
```

## The manifest

<!-- file: examples/tutorial/09-project/orin.toml -->
```toml
[package]
name = "shapes-app"
version = "0.1.0"
entry = "src/main.or"

[modules.geometry]
allowed_dependencies = []

[dependencies]
banner = { path = "banner" }
```

`[package]` needs a `name`; `version` and `entry` have defaults (`0.0.0`, `src/main.or`). `[dependencies]` lists other
packages: here `banner` is a path dependency. The same line is what `orin add --path banner` writes, and
`orin add --git URL --tag TAG` adds a Git dependency. `orin fetch` records the resolution in `orin.lock`; a build never
changes the lock, and `orin update` does. (Registry lookup is not implemented.)

`[modules.geometry]` with `allowed_dependencies = []` is an architecture rule: the files of the `geometry` module may not
import any other module of the package. Breaking it is a compile error (E0501).

## Modules

A directory with a `module.or` is a **module**; the `module.or` is its public face and says what the module exports. Files
inside the directory import each other freely, but code outside may import only the module itself.

<!-- file: examples/tutorial/09-project/src/geometry/module.or -->
```ts
// A module: only what is exported here is visible outside the directory.
export { Rect, area, perimeter } from "./rect";
```

<!-- file: examples/tutorial/09-project/src/geometry/rect.or -->
```ts
export type Rect = { w: int; h: int; };

export function area(r: Rect): int {
  return r.w * r.h;
}

export function perimeter(r: Rect): int {
  return 2 * (r.w + r.h);
}
```

Everything is private to its file unless marked `export`. `import { area } from "./geometry/rect"` from `main.or` would be
an error (E0302: cannot import private file; import the module itself).

## The program and the dependency

<!-- file: examples/tutorial/09-project/src/main.or -->
```ts
import { banner } from "banner";
import { Rect, area, perimeter } from "./geometry";

function main(): void {
  console.log(banner("Rectangles"));
  const r = Rect { w: 3, h: 4 };
  console.log("area " + area(r).toString() + ", perimeter " + perimeter(r).toString());
}
```

The import `"banner"` (no `./`) names the dependency; it resolves to the dependency's `src/module.or`:

<!-- file: examples/tutorial/09-project/banner/orin.toml -->
```toml
[package]
name = "banner"
version = "0.1.0"
```

<!-- file: examples/tutorial/09-project/banner/src/module.or -->
```ts
// The public face of the `banner` package.
export function banner(title: string): string {
  let line = "";
  let i = 0;
  while (i < title.length.toInt() + 4) {
    line += "=";
    i += 1;
  }
  return line + "\n| " + title + " |\n" + line;
}
```

Imports are statically resolved: `./geometry` means `geometry.or`, or else `geometry/module.or`; `std:fs` is the standard
library. Import cycles are errors.

## Run and test

Run these inside `examples/tutorial/09-project` (or copy it elsewhere):

```sh
orin run
orin test
orin deps --tree
```

`orin run` finds the `orin.toml`, builds the package and runs it:

<!-- file: examples/tutorial/09-project/expected.out -->
```text
==============
| Rectangles |
==============
area 12, perimeter 14
```

The tests are in `tests/`; `orin test` runs `tests/**/*_test.or`, and the `@Test` functions of the package itself:

<!-- file: examples/tutorial/09-project/tests/area_test.or -->
```ts
import { assertEq } from "std:test";
import { Rect, area, perimeter } from "../src/geometry";

@Test
function areaOfRect(): void {
  assertEq(area(Rect { w: 3, h: 4 }), 12, "area");
}

@Test
function perimeterOfRect(): void {
  assertEq(perimeter(Rect { w: 3, h: 4 }), 14, "perimeter");
}
```

<!-- file: examples/tutorial/09-project/expected.test.out -->
```text
PASS area_test.areaOfRect
PASS area_test.perimeterOfRect
2 passed, 0 failed
```

Other everyday commands: `orin check` (type-check), `orin fmt` (format), `orin build --release`, `orin clean`, and
`orin init NAME --lib` for a library package. Several packages can be grouped in a workspace
(`orin-workspace.toml`, [workspace.md](../workspace.md)).

## Try it

Add a function `square(side: int): Rect` to `rect.or`, export it from `geometry/module.or` and print its area from `main`.
Then try to import `"./geometry/rect"` directly from `main.or` and read the error.

Reference: [modules, packages and preludes](../reference/06-modules-packages.md), [CLI guide](../cli.md),
[workspaces](../workspace.md).

Next: [10. Concurrency](10-concurrency.md).
