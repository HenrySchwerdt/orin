#!/usr/bin/env python3
"""Execute verifier-accepted IForward MIR with destination == index (C/LLVM, facts on/off)."""
import argparse
import pathlib
import subprocess
import tempfile

from runtime_files import rt_inc, rt_src, rt_llvm  # the runtime source list: tools/runtime-sources.txt
ROOT = pathlib.Path(__file__).resolve().parents[1]
DRIVER = '''
import { Host, useProcess } from "std:host";
import { args } from "std:process";
import { assertEqUsize } from "std:test";
import { forwardingOntoIndex } from "../../compiler/tests/emit_test";
import { verify } from "../../compiler/verify";
import { emitCFacts } from "../../compiler/backends/c";
import { emitLlvmFacts } from "../../compiler/backends/llvm";

function main(host: Host): void {
  useProcess(host, proc => {
    const a = args(proc);
    const initial: usize = a[2] == "0" ? 0 : 1;
    const p = forwardingOntoIndex(initial);
    assertEqUsize(verify(p).errors.length, 0, "regression MIR must pass the independent verifier");
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
    with tempfile.TemporaryDirectory(prefix="forward-assert-", dir=ROOT / "build") as temp:
        out = pathlib.Path(temp)
        source = out / "driver.or"
        source.write_text(DRIVER)
        driver = out / "driver"
        generated = out / "driver.c"
        run([args.orinc, "compile", str(source), "-o", str(generated)])
        runtime = rt_src()
        run(["cc", "-O1", "-w", *rt_inc(), str(generated), *runtime, "-lm", "-o", str(driver)])
        for backend in ("c", "llvm"):
            for facts in ("plain", "facts"):
                for initial in ("0", "1"):
                    label = f"{backend} {facts} initial={initial}"
                    emitted = run([str(driver), backend, facts, initial])
                    target = out / ("case.ll" if backend == "llvm" else "case.c")
                    target.write_text(emitted)
                    extra = rt_llvm("legacy") if backend == "llvm" else []  # hand-built MIR has no $rt: legacy codegen, frozen runtime
                    exe = out / "case"
                    # LLVM's assembler also rejects duplicate SSA register names.
                    run(["clang", "-O2", "-w", *rt_inc("legacy"), str(target), *rt_src("legacy"), *extra, "-lm", "-o", str(exe)])
                    result = subprocess.run([str(exe)], cwd=ROOT, text=True, capture_output=True, timeout=10)
                    if result.returncode != 0 or result.stdout or result.stderr:
                        failures.append(f"{label}: exit {result.returncode}: {result.stdout}{result.stderr}")
                    else:
                        print("PASS " + label, flush=True)
    if failures:
        raise RuntimeError("\n".join(failures))
    print("8 forward assertion execution cases passed")


if __name__ == "__main__":
    main()
