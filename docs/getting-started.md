# Getting started

Orin is a pre-release language: read the [stability policy](stability.md) before depending on it.

## Install

**Homebrew** (macOS arm64 and Intel, Linux x86-64 and arm64):

```sh
brew install orin-lang/orin/orin
```

**install.sh** (Linux, macOS): downloads a release, verifies its sha256, installs to `~/.orin`:

```sh
curl -fsSL https://raw.githubusercontent.com/orin-lang/orin-lang/main/install.sh | sh
```

**From source:** needs a C compiler, `python3`, `gzip` and `sha256sum`/`shasum`.

```sh
git clone https://github.com/orin-lang/orin-lang && cd orin-lang
./tools/bootstrap.sh
```

The compiler lands in `build/bootstrap/orin2` ([bootstrap.md](bootstrap.md)). Windows: WSL2
([windows.md](windows.md)). All options and troubleshooting: [install.md](install.md).

Check the install:

```sh
orin doctor
```

## Requirements

- A C compiler (`cc`, gcc or clang) on PATH. The default backend emits C. `orin doctor` checks that it can
  compile and link a program, and prints a fix if not.
- Optional: `z3`, only for `orin verify` (contract verification, see [contracts.md](contracts.md)).
- Optional: LLVM for `--backend=llvm` and release builds; `orin toolchain install` fetches the pinned
  version, and `orin doctor` reports whether it is present ([cli.md](cli.md)).

## First program

Save as `hello.or`:

```ts
function main(): void {
  console.log("Hello, Orin!");
}
```

```sh
orin run hello.or
orin build hello.or -o hello && ./hello
```

For a project with an `orin.toml`, there is no `orin new`; use `orin init`:

```sh
orin init hello
cd hello
orin run
orin test
```

More examples are in [`examples/`](../examples/hello.or). Commands: [cli.md](cli.md).

## Editor

The VS Code extension in [`editors/vscode`](../editors/vscode/README.md) gives highlighting and the language
server. It finds `orin` on PATH; see [install.md](install.md#editor-vs-code).

## Where next

- [Tutorial](tutorial/README.md)
- [notes-service](../examples/projects/notes-service/README.md): a small concurrent JSON service with unit tests, a project to copy
- [wc](../examples/projects/wc/README.md): a command-line tool (flags, stdin, exit codes) with unit tests, a project to copy
- [Language reference](reference/README.md)
- [Standard library](std.md)
- [Orin for TypeScript developers](ts-developers.md)
- [Stability policy](stability.md) and [known limitations](known-limitations.md)
