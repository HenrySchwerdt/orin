#!/usr/bin/env python3
"""Exact JSON-number parity, independent oracle and deterministic scaling.

python3 tools/check_jsonnumber.py [--orinc build/bootstrap/orin2] [--skip-bench]
All generated sources/results stay in build/jsonnumber. Only Python's standard
library is used. Benchmark times include startup and input construction.
"""
import argparse
from decimal import Decimal
import json
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/jsonnumber"
GRAMMAR = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?", re.ASCII)


def run(args, *, env=None):
    r = subprocess.run([str(x) for x in args], cwd=ROOT, capture_output=True,
                       text=True, timeout=180, env=env)
    if r.returncode:
        raise RuntimeError(f"{args}: exit {r.returncode}\n{r.stdout}{r.stderr}")
    return r.stdout


def build(orinc, source, backend, contracts=False, sanitize=False):
    stem = source.stem + "_" + backend + ("_checked" if contracts else "_plain")
    if sanitize:
        stem += "_san"
    generated = OUT / (stem + (".ll" if backend == "llvm" else ".c"))
    cmd = [orinc, "compile", source, "--backend=" + backend, "-o", generated]
    if contracts:
        cmd += ["--check-contracts"]
    run(cmd)
    binary = OUT / stem
    cmd = ["clang", "-O2", "-w", "-I", "runtime/core", generated,
           "runtime/core/orin_runtime.c", "runtime/platform/orin_platform.c", "-lm", "-o", binary]
    if backend == "llvm":
        cmd += ["runtime/core/orin_runtime_llvm.c"]
    if sanitize:
        cmd += ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"]
    run(cmd)
    return binary


def oracle_cases():
    rng = random.Random(20261015)
    tokens = [str(n) for n in [-2**63-1, -2**63, -2**63+1, 2**63-2, 2**63-1, 2**63, 2**53+1]]
    for _ in range(1200):
        integer = str(rng.randrange(10**rng.randrange(0, 45)))
        fraction = ""
        if rng.randrange(2):
            fraction = "." + "".join(str(rng.randrange(10)) for _ in range(rng.randrange(1, 26)))
        exponent = ""
        if rng.randrange(4):
            e = rng.randrange(-90, 91)
            exponent = rng.choice(["e", "E"]) + ("-" if e < 0 else rng.choice(["", "+"]))
            exponent += "0" * rng.randrange(4) + str(abs(e))
        tokens.append(rng.choice(["", "-"]) + integer + fraction + exponent)
    # Mutations independently classified by a full-match grammar, not the Orin scanner.
    for original in tokens[:800]:
        at = rng.randrange(len(original) + 1)
        tokens.append(original[:at] + rng.choice(["x", ".", "+", "e", " ", "\x00", "0"]) + original[at:])
    entries = []
    for token in tokens:
        kind, expected = "syntax", 0
        if GRAMMAR.fullmatch(token):
            parts = re.split("[eE]", token)
            exponent = int(parts[1]) if len(parts) == 2 else 0
            # Mutations can turn coefficient digits into astronomic exponents,
            # beyond Decimal's own exponent storage. These generated mantissas
            # have <100 bytes: nonzero *10^(+/- >1000) cannot be an i64 integer.
            assert len(parts[0]) < 100
            if abs(exponent) > 1000:
                if Decimal(parts[0]) == 0:
                    kind, expected = "ok", 0
                else:
                    kind = "range" if exponent > 0 else "fraction"
            else:
                value = Decimal(token)  # exact construction; no binary float intermediary
                if value != value.to_integral_value():
                    kind = "fraction"
                elif not -2**63 <= value <= 2**63-1:
                    kind = "range"
                else:
                    kind, expected = "ok", int(value)
        literal = "-9223372036854775807 - 1" if expected == -2**63 else str(expected)
        entries.append(f"OracleCase {{ token: {json.dumps(token).replace("\\u0000", "\\x00")}, kind: \"{kind}\", value: {literal} }}")
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orinc", default="build/bootstrap/orin2")
    parser.add_argument("--skip-bench", action="store_true", help="run vectors/oracles and backend checks only")
    args = parser.parse_args()
    orinc = (ROOT / args.orinc).resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    test = (ROOT / "tests/std/jsonnumber_test.or").read_text()
    names = re.findall(r"@Test\s+function (\w+)\(", test)
    if not names:
        raise RuntimeError("no jsonnumber tests discovered")
    entries = oracle_cases()
    source = OUT / "oracle.or"
    source.write_text(test.replace("@Test", "") + '''
type OracleCase = { token: string; kind: string; value: int; };
function main(): void {
''' + "".join(f"  {name}();\n" for name in names) +
                      "  const cases = [\n" + ",\n".join(entries) + '''];
  for (const c of cases) {
    const n = jsonNumber(c.token, c.token.length + 1);
    if (c.kind == "syntax") {
      assert(n.isErr(), "Python regex rejects token");
      assertEqString(kindName(n.unwrapErr().kind), "syntax", "oracle syntax kind");
    } else {
      assertEqString(n.unwrap().token, c.token, "oracle exact lexeme");
      const r = numberAsInt(n.unwrap());
      if (c.kind == "ok") { assertEq(r.unwrap(), c.value, c.token); }
      else { assertEqString(kindName(r.unwrapErr().kind), c.kind, c.token); }
    }
  }
  console.log("jsonnumber oracle passed");
}
''')
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0")
    for backend, contracts, sanitize in [("c", False, False), ("c", True, False),
                                          ("llvm", False, False), ("llvm", True, False),
                                          ("c", True, True)]:
        binary = build(orinc, source, backend, contracts, sanitize)
        assert run([binary], env=env) == "jsonnumber oracle passed\n"
        print(f"PASS {len(entries)} independent cases + tests: {backend} contracts={contracts} sanitizers={sanitize}", flush=True)
    if args.skip_bench:
        return
    for size in [65536, 262144, 1048576]:
        source = OUT / f"benchmark_{size}.or"
        source.write_text('''import { ByteBuilder } from "std:bytes";
import { assert } from "std:test";
import { jsonNumber, numberAsInt } from "std:jsonnumber";
function main(): void {
  let z = new ByteBuilder(); let e = new ByteBuilder();
  let i: usize = 0;
''' + f"  while (i < {size}) {{ z.appendU8(48); e.appendU8(57); i += 1; }}\n" + '''
  const zeros = z.build().toRawString(); const nines = e.build().toRawString();
  const huge = "1e" + nines; const zero = "-0e-" + nines;
''' + f'  const cancel = "0." + zeros + "1e{size+1}";\n' + '''
  const invalid = "1e" + zeros + "x";
  let round = 0; let sum = 0;
  while (round < 16) {
    assert(numberAsInt(jsonNumber(huge, huge.length).unwrap()).isErr(), "huge range"); sum += 1;
    assert(numberAsInt(jsonNumber(zero, zero.length).unwrap()).unwrap() == 0, "zero");
    sum += numberAsInt(jsonNumber(cancel, cancel.length).unwrap()).unwrap();
    assert(jsonNumber(invalid, invalid.length).isErr(), "invalid suffix"); sum += 1;
    round += 1;
  }
  console.log(sum.toString());
}
''')
        for backend in ["c", "llvm"]:
            binary = build(orinc, source, backend)
            assert run([binary]) == "48\n"
            elapsed = []
            for _ in range(3):
                start = time.perf_counter()
                assert run([binary]) == "48\n"
                elapsed.append(time.perf_counter() - start)
            print(f"BENCH {backend} payload={size} rounds=16 median_s={statistics.median(elapsed):.6f} checksum=48", flush=True)


if __name__ == "__main__":
    main()
