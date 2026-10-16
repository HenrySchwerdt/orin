# protocol

The Orin protocol test harness: a port of `tools/test_lsp.py` and `tools/test_mcp.py` (ADR-0047 phase 5). It starts the
compiler under test as `orin lsp` (LSP, JSON-RPC with `Content-Length` framing) or `orin mcp` (MCP 2025-06-18, one JSON
document per line) and speaks the protocol with it over stdio: initialize, diagnostics, definition, hover, references,
rename, formatting, completion, `check`/`inspect`/`edit`/`graph`/`diff`/`build`/`test` tool calls, permission refusals and
shutdown. Every case of the Python scripts exists here with the same requests, assertions and messages.

```sh
tools/protocol.sh lsp --orin build/bootstrap/orin2
tools/protocol.sh mcp --orin build/bootstrap/orin2
tools/protocol.sh lsp                       # builds compiler/main.or with build/bootstrap/orin2 first (--orin2 PATH)
tools/protocol.sh --unit-tests
```

Flags: `lsp|mcp`, `--orin PATH` (compiler binary to test), `--orin2 PATH` (bootstrapped compiler that builds it), `--root`.
Output: `FAIL: <what>` per failed check and a summary line (`test_lsp: N checks, M failed`, `N checks, M failures`); exit
status 0 all checks passed, 1 a check failed or the server died, 2 usage. Details and the parity check: `docs/testing.md`,
"Protocol harness (Orin)".

Layout: `src/main.or` (flow, build of the compiler under test, summary), `cli.or` (argparse-compatible options),
`session.or` (the server process and the LSP / MCP clients), `lsp.or` and `mcp.or` (the test cases), `rpc.or` (framing,
positions), `jx.or` (JSON helpers), `text.or`; `tests/*_test.or` are `@Test` unit tests of the pure helpers.
`tools/protocol.sh` builds it with the bootstrapped compiler into `build/protocol/`.

The language has no API for a child process with pipes (`std:io` has `shell` and `shellTimeout`, which run a command to
completion), so `session.or` starts the server in the background through the shell, with its stdin on a named pipe and
its stdout on a file, writes messages with `cat` and polls the file for complete frames. See the header of `session.or`.
