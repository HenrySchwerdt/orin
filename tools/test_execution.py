#!/usr/bin/env python3
"""ADR-0045: native deadline, cleanup, C/LLVM, CLI and MCP regression checks.

python3 tools/test_execution.py [--orinc build/bootstrap/orin2] [--native-only]
Every subprocess has an independent Python safety deadline. Native child tests
capture pipes: an un-killed descendant retaining stdout/stderr prevents EOF.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from runtime_files import rt_inc, rt_src, rt_llvm  # the runtime source list: tools/runtime-sources.txt

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/portable"


def run(cmd, *, timeout=30, env=None, input=None, expected=0):
    result = subprocess.run([str(x) for x in cmd], cwd=ROOT, text=True,
                            capture_output=True, timeout=timeout, env=env, input=input)
    if result.returncode != expected:
        raise RuntimeError(f"{cmd}: exit {result.returncode}\n{result.stdout}{result.stderr}")
    return result


def native_tests():
    for sanitized in [False, True]:
        exe = OUT / ("process_san" if sanitized else "process")
        cmd = ["cc", "-Wall", "-Wextra", "-O1", "-g", "runtime/platform/tests/process_test.c",
               "runtime/platform/orin_platform.c", "-o", exe]
        if sanitized:
            cmd += ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"]
        run(cmd)
        env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0")
        cases = [("printf 'hello\\n'; exit 0", "1", 0),
                 ("exit 7", "1", 7), ("exit 124", "1", 124),
                 ("kill -KILL $$", "1", -1),
                 ("while :; do :; done", "1", -2),
                 ("trap '' TERM; (trap '' TERM; sleep 30) & wait", "1", -2),
                 ("sleep 30 & exit 0", "1", 0),
                 ("echo MUST_NOT_RUN", "0", -1),
                 ("echo MUST_NOT_RUN", "-1", -1),
                 ("exit 0", "9223372036854775807", 0),
                 ('''printf '%s\\n' 'space value' "quote'value"''', "1", 0)]
        for command, seconds, status in cases:
            start = time.monotonic()
            result = run([exe, command, seconds], timeout=5, env=env)
            assert result.stdout.endswith(f"\nstatus={status}\n"), result
            assert "MUST_NOT_RUN" not in result.stdout, result
            if status == -2:
                assert 0.9 <= time.monotonic() - start < 5, result
        result = run([exe, "sleep 30 & wait", "1"], timeout=5,
                     env=dict(env, ORIN_TEST_INTERRUPTS="1"))
        assert result.stdout.endswith("\nstatus=-2\n"), result
        result = run([exe, "echo MUST_NOT_RUN", "1"], timeout=5,
                     env=dict(env, ORIN_TEST_IGNORE_CHLD="1"))
        assert result.stdout == "\nstatus=-1\n", result
        print(f"PASS native exits, duration validation, signal, hang, child cleanup, EINTR; sanitized={sanitized}", flush=True)


def direct_tests(orinc):
    source = OUT / "bounded.or"
    source.write_text('''import { Host, useProcess } from "std:host";
import { shellTimeout } from "std:io";
function main(host: Host): void {
  useProcess(host, proc => {
    console.log(shellTimeout(proc, "printf 'hello\\n'; exit 7", 1).toString());
    console.log(shellTimeout(proc, "exit 124", 1).toString());
    console.log(shellTimeout(proc, "sleep 30 & wait", 1).toString());
    console.log(shellTimeout(proc, "echo MUST_NOT_RUN", 0).toString());
  });
}
''')
    for backend in ["c", "llvm"]:
        generated = OUT / ("bounded.c" if backend == "c" else "bounded.ll")
        exe = OUT / ("bounded_" + backend)
        run([orinc, "compile", source, "--backend=" + backend, "-o", generated])
        cmd = ["clang", "-O2", "-w", *rt_inc(), generated, *rt_src(), "-o", exe]
        if backend == "llvm":
            cmd += rt_llvm()
        run(cmd)
        result = run([exe], timeout=5)
        assert result.stdout == "hello\n7\n124\n-2\n-1\n", result
        denied = run([exe], env=dict(os.environ, ORIN_DENY="process"), expected=101)
        assert "hello" not in denied.stdout and "denied" in denied.stderr, denied
        print(f"PASS {backend} direct runtime status and process denial", flush=True)
    source.write_text('''import { Host, useStdio } from "std:host";
import { shellTimeout } from "std:io";
function main(host: Host): void {
  useStdio(host, io => { shellTimeout(io, "true", 1); });
}
''')
    bad = run([orinc, "check", source], expected=1)
    assert "E0471" in bad.stderr, bad
    print("PASS wrong-family process grant rejected", flush=True)
    source.write_text('''import { Host, useProcess } from "std:host";
import { ProcessGrant } from "std:process";
import { shellTimeout } from "std:io";
@Requires(shellTimeout(proc, "true", 1) == 0)
function impure(proc: ProcessGrant): void {}
function main(host: Host): void { useProcess(host, proc => { impure(proc); }); }
''')
    bad = run([orinc, "check", source], expected=1)
    assert "E0416" in bad.stderr, bad
    source.write_text(source.read_text().replace('@Requires(shellTimeout(proc, "true", 1) == 0)\n', '')
                      .replace('function impure(proc: ProcessGrant): void {}',
                               'function impure(proc: ProcessGrant): void { shellTimeout(proc, "true", 1); }'))
    effects = run([orinc, "effects", source, "--format=json"])
    assert "Process.Spawn" in effects.stdout, effects
    print("PASS impure contract rejected and Process.Spawn effect retained", flush=True)



def deadline_env(root):
    # Fail if a future runner consults an external timeout utility, even on Linux.
    bin_dir = root / "fake-bin"
    bin_dir.mkdir()
    for name in ["timeout", "gtimeout"]:
        path = bin_dir / name
        path.write_text("#!/bin/sh\necho external-timeout-must-not-run >&2\nexit 77\n")
        path.chmod(0o755)
    return dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ.get("PATH", ""))


def cli_tests(orinc):
    # Quoted directory and output paths exercise the unchanged shell quoting.
    with tempfile.TemporaryDirectory(prefix="orin 'execution ") as directory:
        env = deadline_env(Path(directory))
        source = Path(directory) / "cases.or"
        source.write_text('''import { exit } from "std:process";
@Test function succeeds(): void { console.log("ok"); }
@Test function exits124(): void { exit(124); }
@Test function hangs(): void { while (true) {} }
''')
        start = time.monotonic()
        result = run([orinc, "test", source, "--timeout", "1", "--format=json",
                      "--out-dir", Path(directory) / "out 'dir"], expected=1, timeout=15, env=env)
        data = json.loads(result.stdout)
        assert data["passed"] == 1 and data["failed"] == 2, data
        rows = {t["name"]: t for t in data["tests"]}
        assert rows["exits124"]["reason"] == "exit 124", rows
        assert rows["exits124"]["exitCode"] == 124, rows
        assert rows["hangs"]["reason"] == "timeout" and rows["hangs"]["exitCode"] == -2, rows
        assert 0.9 <= time.monotonic() - start < 15
        result = run([orinc, "test", source, "--timeout", "0", "--filter", "succeeds"], env=env)
        assert "1 passed, 0 failed" in result.stdout, result
        print("PASS CLI success, ordinary exit 124, native hang deadline, quoted paths, explicit unlimited", flush=True)


def mcp_tests(orinc):
    with tempfile.TemporaryDirectory(prefix="orin-mcp execution ") as directory:
        root = Path(directory)
        env = deadline_env(root)
        (root / "ok.or").write_text('function main(): void { console.log("ok"); }\n')
        (root / "ok.out").write_text("ok\n")
        (root / "exit.or").write_text('// exit: 7\nimport { exit } from "std:process";\nfunction main(): void { exit(7); }\n')
        (root / "hang.or").write_text('// exit: -2\nfunction main(): void { while (true) {} }\n')
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "execution-test", "version": "1"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"}]
        for ident, entry in enumerate(["ok.or", "exit.or", "hang.or"], 2):
            msgs.append({"jsonrpc": "2.0", "id": ident, "method": "tools/call",
                         "params": {"name": "test", "arguments": {"entry": entry}}})
        result = run([orinc, "mcp", "--root", root, "--repo", ROOT, "--allow-exec"],
                     input="\n".join(map(json.dumps, msgs)) + "\n", timeout=30, env=env)
        responses = {r["id"]: r for r in map(json.loads, result.stdout.splitlines())}
        values = []
        for ident in [2, 3, 4]:
            payload = responses[ident]["result"]
            assert not payload["isError"], payload
            values.append(json.loads(payload["content"][0]["text"]))
        assert values[0]["passed"] and values[0]["exit"] == 0, values
        assert values[1]["passed"] and values[1]["exit"] == 7, values
        assert not values[2]["passed"] and values[2]["exit"] == -2, values
        assert values[2]["why"] == "timeout after 10 seconds", values
        print("PASS MCP success, expected nonzero, explicit timeout status (cannot pass via exit:-2)", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orinc", default="build/bootstrap/orin2")
    parser.add_argument("--native-only", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    native_tests()
    if not args.native_only:
        orinc = (ROOT / args.orinc).resolve()
        direct_tests(orinc)
        cli_tests(orinc)
        mcp_tests(orinc)


if __name__ == "__main__":
    main()
