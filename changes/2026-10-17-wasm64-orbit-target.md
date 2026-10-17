- **WebAssembly target `wasm64-orbit` (ADR-0055).** `orin build --target=wasm64-orbit` compiles a program into a
  freestanding wasm64 module for the Orbit isolate runtime: no WASI, imports only the Orbit capabilities it reaches
  (`orbit:log/v1`, `orbit:clock/v1`), exports `orin_main`, and carries an `orbit.manifest` section derived from the effect
  analysis; effects the target cannot provide (files, network, processes, tasks) fail the build with E0523. A new
  WebAssembly L0 (`runtime/platform/orbit/`, with its own allocator and glibc-exact float text) replaces libc; the pure
  L0 primitives are shared with the native layer (`orin_platform_pure.h`). The conformance suites run as modules under
  Node in CI (`tools/test_wasm.sh`, `tools/run_tests.py --target wasm64-orbit`). Guide: `docs/wasm.md`.
