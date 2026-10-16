#!/usr/bin/env python3
"""Bounded JSON document validation: independent Python trees, backends and scaling.
Run: python3 tools/check_jsonvalue.py [--orinc build/bootstrap/orin2]
No dependencies outside Python's standard library and the repository toolchain.
"""
import argparse
import json
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/jsonvalue"


def run(args, env=None):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, text=True,
                            capture_output=True, timeout=180, env=env)
    if result.returncode:
        raise RuntimeError(f"{args}: {result.returncode}\n{result.stdout}{result.stderr}")
    return result.stdout


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
    cmd = ["clang", "-O1" if sanitize else "-O2", "-w", "-I", "runtime", generated,
           "runtime/orin_runtime.c", "platform/orin_platform.c", "-o", binary]
    if backend == "llvm":
        cmd += ["runtime/orin_runtime_llvm.c"]
    if sanitize:
        cmd += ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"]
    run(cmd)
    return binary


class Number:
    def __init__(self, text):
        self.text = text

    def __eq__(self, other):
        return isinstance(other, Number) and self.text == other.text


class Object(list):
    pass


def literal(s):
    # Emit raw UTF8 bytes, avoiding differences between JSON/Orin escape syntax.
    return '"' + "".join('\\"' if c == 34 else '\\\\' if c == 92 else chr(c)
                        if 32 <= c < 127 else f"\\x{c:02x}" for c in s.encode("utf-8")) + '"'


def render(v, ascii_strings=False, pretty=False, depth=0):
    if isinstance(v, Number):
        return v.text
    if isinstance(v, Object):
        sep = ",\n" + "  " * depth if pretty else ","
        colon = ": " if pretty else ":"
        return "{" + sep.join(json.dumps(k, ensure_ascii=ascii_strings) + colon +
                              render(x, ascii_strings, pretty, depth + 1) for k, x in v) + "}"
    if isinstance(v, list):
        sep = ",\n" + "  " * depth if pretty else ","
        return "[" + sep.join(render(x, ascii_strings, pretty, depth + 1) for x in v) + "]"
    return json.dumps(v, ensure_ascii=ascii_strings, separators=(",", ":"))


def constructor(v):
    if isinstance(v, Number):
        return f"ValueNumber(jsonNumber({literal(v.text)}, 1024).unwrap())"
    if isinstance(v, Object):
        return "ValueObject([" + ",".join("JsonMember { key: " + literal(k) + ", value: " + constructor(x) + " }" for k, x in v) + "])"
    if isinstance(v, list):
        return "ValueArray([" + ",".join(constructor(x) for x in v) + "])"
    if v is None:
        return "ValueNull"
    if isinstance(v, bool):
        return "ValueBool(" + str(v).lower() + ")"
    return "ValueString(" + literal(v) + ")"


def oracle_cases():
    rng = random.Random(20261016)
    numbers = ["-0", "-0.00", "1.00e+003", "9007199254740993", "18446744073709551615",
               "-9223372036854775808", "1e999", "1e-999", "0E-999999999999999999999999999"]
    strings = ["", "a/b~", "a.b", "\"\\", "é中😀\uffff", "\u2028\u2029", "\n\r\t\b\f\x00",
               "".join(chr(i) for i in range(32))]
    atoms = [None, True, False] + [Number(x) for x in numbers] + strings

    def generate(depth):
        mode = rng.randrange(5) if depth < 4 else 0
        if mode < 3:
            return rng.choice(atoms)
        if mode == 3:
            return [generate(depth + 1) for _ in range(rng.randrange(6))]
        return Object((f"k{i}_é/~", generate(depth + 1)) for i in range(rng.randrange(6)))

    values = atoms + [generate(0) for _ in range(160)]
    entries = []
    for v in values:
        text = " \n" + render(v, ascii_strings=True, pretty=True) + "\r\n"
        # Python's independent parser constructs ordered objects and captures each
        # original numeric token without a float intermediary.
        parsed = json.loads(text, parse_int=Number, parse_float=Number, object_pairs_hook=Object)
        assert parsed == v
        entries.append("OracleCase { text: " + literal(text) + ", compact: " + literal(render(v)) +
                       ", value: " + constructor(v) + ", preserve: false }")
    duplicate = Object([("a", Number("1")), ("a", Number("2"))])
    entries.append("OracleCase { text: " + literal('{"a":1,"\\u0061":2}') +
                   ", compact: " + literal(render(duplicate)) + ", value: " + constructor(duplicate) + ", preserve: true }")
    return entries


BENCHMARK = '''import { Host, useProcess } from "std:host";
import { args } from "std:process";
import { assert, assertEqString, assertEqUsize } from "std:test";
import { JsonReadOptions, JsonDuplicatePolicy, parseDocument, writeDocument, defaultJsonLimits } from "std:jsonvalue";
function source(n: usize, mode: string): string {
  if (mode == "string") {
    let s = "a"; while (s.length < n) { s = s + s; }
    return "\\\"" + s.substring(0,n) + "\\\"";
  }
  let parts: string[] = [];
  const object = mode == "object" || mode == "duplicate";
  const count = n / (object ? 24 : 8).toUsize();
  parts.push(object ? "{" : "["); let i: usize = 0;
  while (i < count) {
    if (i > 0) { parts.push(","); }
    if (object) {
      const key = mode == "duplicate" ? "a" : "k" + i.toString();
      parts.push("\\\"" + key + "\\\":");
    }
    parts.push("1.00e+2"); i += 1;
  }
  parts.push(object ? "}" : "]"); return parts.join("");
}
function measure(n: usize, mode: string): void {
  const s = source(n,mode);
  let l = defaultJsonLimits(); l.maxInputBytes = n*2+64;
  l.maxStringBytes = n+64; l.maxDecodedStringBytes = n*2+64;
  l.maxNodes = n+64; l.maxContainerItems = n+64;
  const opt = JsonReadOptions { limits:l, duplicates: mode == "duplicate" ? PreserveDuplicates : RejectDuplicates };
  let checksum: usize = 0; let i = 0;
  while (i < 2) {
    const v = parseDocument(s,opt).unwrap();
    const output = writeDocument(v,l).unwrap();
    assertEqString(output,s,"independent generated compact source");
    checksum += output.length; i += 1;
  }
  assert(parseDocument(s+"x",opt).isErr(),"invalid suffix rejected");
  assertEqUsize(parseDocument(s+"x",opt).unwrapErr().offset,s.length,"suffix byte offset");
  if (mode == "duplicate") {
    const strict = JsonReadOptions { limits:l, duplicates:RejectDuplicates };
    assert(parseDocument(s,strict).isErr(),"duplicate-heavy rejection");
  }
  console.log(checksum.toString());
}
function main(host: Host): void {
  useProcess(host, proc => { const a=args(proc); measure(parseInt(a[0]).unwrap().toUsize(),a[1]); });
}
'''


def expected_source(n, mode):
    if mode == "string":
        return '"' + "a" * n + '"'
    if mode == "numbers":
        return "[" + ",".join(["1.00e+2"] * (n // 8)) + "]"
    return "{" + ",".join(json.dumps("a" if mode == "duplicate" else f"k{i}") + ":1.00e+2"
                           for i in range(n // 24)) + "}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orinc", default="build/bootstrap/orin2")
    opts = parser.parse_args()
    orinc = (ROOT / opts.orinc).resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    tests = (ROOT / "tests/std/jsonvalue_test.or").read_text()
    names = re.findall(r"@Test\s+function (\w+)\(", tests)
    entries = oracle_cases()
    oracle = OUT / "oracle.or"
    oracle.write_text(tests.replace("@Test", "") + '''
type OracleCase = { text: string; compact: string; value: JsonValue; preserve: bool; };
function main(): void {
''' + "".join(f"  {name}();\n" for name in names) +
                      "  const cases = [\n" + ",\n".join(entries) + '''];
  for (const c of cases) {
    let opt = defaultJsonOptions();
    if (c.preserve) { opt.duplicates = PreserveDuplicates; }
    const parsed = parseDocument(c.text,opt).unwrap();
    assert(equal(parsed,c.value),"independent Python source tree");
    assertEqString(write(c.value),c.compact,"independent Python writer vector");
    assertEqString(write(parsed),c.compact,"independent combined vector");
  }
  console.log("jsonvalue oracle passed");
}
''')
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0")
    for backend, contracts, sanitize in [("c", False, False), ("c", True, False),
                                          ("llvm", False, False), ("llvm", True, False),
                                          ("c", True, True)]:
        binary = build(orinc, oracle, backend, contracts, sanitize)
        assert run([binary], env) == "jsonvalue oracle passed\n"
        print(f"PASS {len(entries)} independent tree/token vectors + {len(names)} test groups: "
              f"{backend} contracts={contracts} sanitizers={sanitize}", flush=True)
    source = OUT / "benchmark.or"
    source.write_text(BENCHMARK)
    binaries = {b: build(orinc, source, b) for b in ["c", "llvm"]}
    for n in [65536, 262144, 1048576]:
        for mode in ["string", "numbers", "object", "duplicate"]:
            size = len(expected_source(n, mode).encode())
            for backend, binary in binaries.items():
                cmd = [binary, n, mode]
                expected = f"{size*2}\n"
                assert run(cmd) == expected
                elapsed = []
                for _ in range(3):
                    start = time.perf_counter(); assert run(cmd) == expected
                    elapsed.append(time.perf_counter() - start)
                print(f"BENCH {backend} mode={mode} n={n} source_bytes={size} rounds=2 "
                      f"median_s={statistics.median(elapsed):.6f} checksum={size*2}", flush=True)


if __name__ == "__main__":
    main()
