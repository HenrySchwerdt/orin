#!/usr/bin/env python3
"""Run the URL assertions through C/LLVM with contracts on/off, then benchmark both backends."""
import argparse
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(args):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, capture_output=True, timeout=180).stdout


def build(orin, source, target, backend, contracts, sanitize):
    generated = target.with_suffix(".ll" if backend == "llvm" else ".c")
    flags = ["--check-contracts"] if contracts else []
    run([orin, "compile", str(source), "-o", str(generated), "--backend=" + backend] + flags)
    sources = [str(generated), "runtime/orin_runtime.c", "platform/orin_platform.c"]
    if backend == "llvm":
        sources.append("runtime/orin_runtime_llvm.c")
    sanitizer = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if sanitize else []
    run(["clang", "-O2", "-w", "-I", "runtime"] + sanitizer + sources + ["-lm", "-o", str(target)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orin", default="build/bootstrap/orin2")
    parser.add_argument("--sanitize", action="store_true")
    parser.add_argument("--skip-bench", action="store_true")
    args = parser.parse_args()
    orin = str((ROOT / args.orin).resolve())
    out = ROOT / "build/url"
    out.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "tests/std/url_test.or").read_text()
    tests = re.findall(r"@Test\s+function\s+(\w+)\(\): void", source)
    if not tests:
        raise RuntimeError("no URL tests discovered")
    harness = out / "assertions.or"
    harness.write_text(source.replace("@Test", "") + "\nfunction main(): void {\n" +
                       "".join("  " + test + "();\n" for test in tests) +
                       '  console.log("URL assertions passed");\n}\n')
    for backend in ("c", "llvm"):
        for contracts in (False, True):
            exe = out / ("assertions-" + backend + ("-contracts" if contracts else "-plain"))
            build(orin, harness, exe, backend, contracts, args.sanitize)
            result = run([str(exe)])
            if result != "URL assertions passed\n":
                raise RuntimeError("unexpected assertion output: " + result)
            print(f"{backend} contracts={contracts}: {len(tests)} test groups passed", flush=True)
        if not args.skip_bench:
            exe = out / ("bench-" + backend)
            build(orin, ROOT / "bench/url/main.or", exe, backend, False, False)
            for repeat in range(3):
                print(f"{backend} benchmark run {repeat + 1}:\n" + run([str(exe)]), end="", flush=True)


if __name__ == "__main__":
    if "ASAN_OPTIONS" not in os.environ:
        os.environ["ASAN_OPTIONS"] = "detect_leaks=0"
    main()
