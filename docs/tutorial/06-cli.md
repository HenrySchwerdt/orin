# 6. A command-line tool

So far the programs only printed. This chapter reads a file, which needs *authority*: in Orin a program can do I/O only
if it is given the right to.

## The program

`06-cli` counts the lines and words of a file and can save the result:

<!-- file: examples/tutorial/06-cli.or -->
```ts
// A small tool: count the lines and words of a file, optionally save a summary.
//   06-cli FILE [SUMMARY]
import { Host, useHost } from "std:host";
import { FsGrant, withFile, readFile, writeFile, Read } from "std:fs";
import { ProcessGrant, args, exit } from "std:process";

type Stats = { lines: int; words: int; };

function countFile(fs: FsGrant, path: string): Result<Stats, string> {
  return withFile(fs, path, Read, f => {
    let lines = 0;
    let words = 0;
    while (true) {
      const line = f.readLine();
      if (line.isNone()) {
        break;
      }
      lines += 1;
      for (const w of line.unwrap().split(" ")) {
        if (w.trim().length > 0) {
          words += 1;
        }
      }
    }
    return Stats { lines: lines, words: words };
  });
}

function run(fs: FsGrant, proc: ProcessGrant): Result<void, string> {
  const argv = args(proc);
  if (argv.length < 1) {
    return Err("usage: 06-cli FILE [SUMMARY]");
  }
  const stats = countFile(fs, argv[0])?;
  const summary = stats.lines.toString() + " lines, " + stats.words.toString() + " words";
  console.log(argv[0] + ": " + summary);
  if (argv.length > 1) {
    writeFile(fs, argv[1], summary + "\n")?;
    console.log("saved: " + readFile(fs, argv[1])?.trim());
  }
  return Ok();
}

function main(host: Host): void {
  useHost(host, (fs, proc, stdio, clock) => {
    const r = run(fs, proc);
    if (r.isErr()) {
      console.error("error: " + r.unwrapErr());
      exit(1);
    }
  });
}
```

Run it on the sample file from the repository root. `orin run` forwards the arguments after the file name; the second
argument is a path for the summary, and its directory must exist:

```sh
mkdir -p build/tutorial
orin run examples/tutorial/06-cli.or examples/tutorial/06-sample.txt build/tutorial/06-summary.txt
```

<!-- file: examples/tutorial/06-cli.out -->
```text
examples/tutorial/06-sample.txt: 4 lines, 16 words
saved: 4 lines, 16 words
```

Without arguments it prints `error: usage: 06-cli FILE [SUMMARY]` to standard error and exits with status 1; with a file
that does not exist, `error: cannot open 'x.txt': No such file or directory`.

## What is in it

**`main(host: Host)`.** A plain `main(): void` has no I/O authority: calling `readFile` there is a compile error (E0470).
A program that does I/O takes a `Host`, the root of authority. `console.log`, `console.error` and `exit` are always
available.

**Grants.** `useHost(host, (fs, proc, stdio, clock) => { ... })` hands the body four *grants*: file system, process
(arguments, `shell`), standard input/output and clock. Every I/O function takes the matching grant as its first
argument: `args(proc)`, `readFile(fs, path)`, `writeFile(fs, path, text)`. Passing grants down as parameters
(`run(fs, proc)`) keeps the code that needs authority visible in its signatures. A grant lives only inside the callback and
cannot be stored or captured by a closure. You can narrow one before passing it on: `useUnder(fs, "data", sub => ...)`
only allows paths inside `data/`, and `useReadOnly(fs, ro => ...)` cannot write. The environment variable
`ORIN_DENY=fs` (also `process`, `stdio`, `clock`, `net`) turns a family off for a run: here `readFile` then returns an
`Err` that says `denied by the host policy`.

**Files.** `readFile` and `writeFile` handle whole files and return a `Result<..., string>`. For streaming,
`withFile(fs, path, Read, f => ...)` opens the file, runs the callback with a `File` handle, and closes the file on every
path. The handle can only be a parameter: it cannot be stored in a variable, record or returned, so a file cannot leak.
`f.readLine()` returns an `Option<string>` (`None` at the end). Opening can fail, so `withFile` itself returns a `Result`,
and `countFile` hands it straight on.

**Errors flow with `?`.** `run` returns `Result<void, string>`; `countFile(...)?` and `writeFile(...)?` return early on
`Err`. Only `main` decides what an error means: print it and `exit(1)`.

The modules used here (`std:host`, `std:fs`, `std:process`) are marked unstable until the I/O interface is frozen;
see [std.md](../std.md).

## Try it

Make the tool accept several files and print one line for each. Remember that `args(proc)` is a `string[]`.

Reference: [ownership, resources, capabilities](../reference/05-ownership-resources-capabilities.md),
[std:host, std:fs](../std.md), [capabilities](../capabilities.md).

Next: [7. Testing](07-testing.md).
