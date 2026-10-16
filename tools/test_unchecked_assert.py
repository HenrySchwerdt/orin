#!/usr/bin/env python3
"""Execute IArrayGetU / IArraySetU MIR on the C and LLVM backends (ADR-0038 lever 2 T2, docs/mir.md v2.6).

variant 0 is verifier-accepted (the unchecked load also overwrites its own index local): it must run to completion with
`--assert-facts` on and off. Variants 1 (index out of bounds) and 2 (an unchecked access on a struct) are NOT verifier-accepted:
only the facts build may run them, and it must exit 70 with the `--assert-facts` message instead of reading out of bounds."""
import argparse
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DRIVER = '''
import { Host, useProcess } from "std:host";
import { args } from "std:process";
import { assertEqUsize } from "std:test";
import { uncheckedMir } from "../../compiler/tests/emit_test";
import { verify } from "../../compiler/verify";
import { emitCFacts } from "../../compiler/backends/c";
import { emitLlvmFacts } from "../../compiler/backends/llvm";
from runtime_files import rt_inc, rt_src, rt_llvm  # the runtime source list: tools/runtime-sources.txt

function main(host: Host): void {
  useProcess(host, proc => {
    const a = args(proc);
    const variant: usize = a[2] == "0" ? 0 : (a[2] == "1" ? 1 : 2);
    const p = uncheckedMir(variant);
    if (variant == 0) {
      assertEqUsize(verify(p).errors.length, 0, "variant 0 must pass the independent verifier");
    } else {
      assertEqUsize(verify(p).errors.length, 1, "variants 1 and 2 must be rejected by rule U1");
    }
    console.log(a[0] == "llvm" ? emitLlvmFacts(p, a[1] == "facts") : emitCFacts(p, a[1] == "facts"));
  });
}
'''


def run(command, **kwargs):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=120, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{command}: exit {result.returncode}\n{result.stdout}{result.stderr}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orinc", default="build/bootstrap/orin2")
    args = parser.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)
    failures = []
    passed = 0
    with tempfile.TemporaryDirectory(prefix="unchecked-assert-", dir=ROOT / "build") as temp:
        out = pathlib.Path(temp)
        source = out / "driver.or"
        source.write_text(DRIVER)
        driver = out / "driver"
        generated = out / "driver.c"
        run([args.orinc, "compile", str(source), "-o", str(generated)])
        runtime = rt_src()
        run(["cc", "-O1", "-w", *rt_inc(), str(generated), *runtime, "-lm", "-o", str(driver)])
        cases = [("0", "plain", 0, ""), ("0", "facts", 0, ""),
                 ("1", "facts", 70, "an unchecked array access is out of bounds"),
                 ("2", "facts", 70, "an unchecked array access on an object that is not an array")]
        for backend in ("c", "llvm"):
            for variant, facts, want, message in cases:
                label = f"{backend} {facts} variant={variant}"
                emitted = run([str(driver), backend, facts, variant])
                target = out / ("case.ll" if backend == "llvm" else "case.c")
                target.write_text(emitted)
                extra = rt_llvm() if backend == "llvm" else []
                exe = out / "case"
                run(["clang", "-O2", "-w", *rt_inc(), str(target), *runtime, *extra, "-lm", "-o", str(exe)])
                result = subprocess.run([str(exe)], cwd=ROOT, text=True, capture_output=True, timeout=10)
                ok = result.returncode == want and (message in result.stderr if want else not result.stdout and not result.stderr)
                if ok:
                    passed += 1
                    print("PASS " + label, flush=True)
                else:
                    failures.append(f"{label}: exit {result.returncode}: {result.stdout}{result.stderr}")
    if failures:
        raise RuntimeError("\n".join(failures))
    print(f"{passed} unchecked access execution cases passed")


if __name__ == "__main__":
    main()
