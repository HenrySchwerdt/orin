#!/usr/bin/env python3
"""Encoding-only parity, sanitizer and deterministic scaling benchmark.

Run after bootstrap: python3 tools/check_encoding.py [--orinc build/bootstrap/orin2]
Builds ordinary-main versions of the actual @Test bodies to run the same checks
under C/LLVM, contracts on/off, and C ASan/UBSan. Benchmarks include startup and
input construction, use three fixed sizes and four rounds, and report medians
of three runs after one warmup. Python's codecs provide independent vectors.
"""
import argparse
import base64
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/encoding"


def run(args, **kw):
    result = subprocess.run([str(x) for x in args], cwd=ROOT,
                            text=True, capture_output=True, timeout=180, **kw)
    if result.returncode:
        raise RuntimeError(f"command failed: {args}\n{result.stdout}{result.stderr}")
    return result.stdout


def compile_orin(orinc, source, backend, contracts=False, sanitize=False):
    stem = source.stem + "_" + backend + ("_checked" if contracts else "_plain")
    if sanitize:
        stem += "_san"
    generated = OUT / (stem + (".ll" if backend == "llvm" else ".c"))
    cmd = [orinc, "compile", source, "--backend=" + backend, "-o", generated]
    if contracts:
        cmd += ["--check-contracts"]
    run(cmd)
    binary = OUT / stem
    cmd = ["clang", "-O2", "-w", "-I", ROOT / "runtime", generated,
           ROOT / "runtime/orin_runtime.c", ROOT / "platform/orin_platform.c", "-o", binary]
    if backend == "llvm":
        cmd += [ROOT / "runtime/orin_runtime_llvm.c"]
    if sanitize:
        cmd += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    run(cmd)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orinc", default="build/bootstrap/orin2")
    opts = parser.parse_args()
    orinc = ROOT / opts.orinc
    OUT.mkdir(parents=True, exist_ok=True)
    tests = (ROOT / "tests/std/encoding_test.or").read_text()
    names = re.findall(r"@Test\s+function (\w+)\(", tests)
    driver = tests.replace("@Test", "")
    driver += "\nfunction main(): void {\n" + "".join(f"  {n}();\n" for n in names)
    # Fixed pseudo-random inputs, independent Python standard-library oracle.
    for n in [0, 1, 2, 3, 17, 64, 257]:
        raw = bytes((i * 73 + n * 19) % 256 for i in range(n))
        hx = raw.hex()
        std = base64.b64encode(raw).decode()
        url = base64.urlsafe_b64encode(raw).decode()
        driver += f'  const b{n} = hexDecode(bytesFromString("{hx}")).unwrap();\n'
        for name, padded, expected in [("hexEncode", None, hx),
                                      ("base64Encode", True, std),
                                      ("base64Encode", False, std.rstrip("=")),
                                      ("base64UrlEncode", True, url),
                                      ("base64UrlEncode", False, url.rstrip("="))]:
            arg = f"b{n}" + (", " + str(padded).lower() if padded is not None else "")
            driver += f'  assertEqString({name}({arg}), "{expected}", "Python oracle");\n'
    driver += '  console.log("encoding parity passed");\n}\n'
    source = OUT / "parity.or"
    source.write_text(driver)
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0")
    for backend, contracts, san in [("c", False, False), ("c", True, False),
                                    ("llvm", False, False), ("llvm", True, False),
                                    ("c", True, True)]:
        binary = compile_orin(orinc, source, backend, contracts, san)
        assert run([binary], env=env) == "encoding parity passed\n"
        print(f"PASS {backend} contracts={contracts} sanitizers={san}", flush=True)
    imports = '''import { ByteBuilder, bytesFromString } from "std:bytes";
import { hexEncode, hexDecode, base64Encode, base64Decode, base64UrlEncode, base64UrlDecode } from "std:encoding";
import { assert } from "std:test";
'''
    for n in [65536, 262144, 1048576]:
        source = OUT / f"bench_{n}.or"
        source.write_text(imports + f'''function main(): void {{
  let builder = new ByteBuilder();
  let i: usize = 0;
  while (i < {n}) {{ builder.appendU8(((i % 256) * 73 % 256).toU8()); i += 1; }}
  const b = builder.build();
  let round = 0;
  let sum: usize = 0;
  while (round < 4) {{
    const h = hexDecode(bytesFromString(hexEncode(b))).unwrap();
    const s = base64Decode(bytesFromString(base64Encode(b, true)), true).unwrap();
    const u = base64UrlDecode(bytesFromString(base64UrlEncode(b, false)), false).unwrap();
    assert(h.equals(b) && s.equals(b) && u.equals(b), "benchmark round trips");
    sum += h.length() + s.length() + u.length();
    round += 1;
  }}
  console.log(sum.toString());
}}
''')
        for backend in ["c", "llvm"]:
            binary = compile_orin(orinc, source, backend)
            expected = f"{n * 12}\n"
            assert run([binary]) == expected
            times = []
            for _ in range(3):
                start = time.perf_counter()
                assert run([binary]) == expected
                times.append(time.perf_counter() - start)
            print(f"BENCH {backend} n={n} rounds=4 median_s={statistics.median(times):.6f} "
                  f"checksum={n * 12}", flush=True)


if __name__ == "__main__":
    main()
