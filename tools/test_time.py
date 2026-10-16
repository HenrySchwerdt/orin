#!/usr/bin/env python3
"""Focused monotonic clock tests: injected failure/range handling and C/LLVM/grants/contracts."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from runtime_files import rt_inc, rt_src, rt_llvm  # the runtime source list: tools/runtime-sources.txt

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/time"


def run(command, expected=0, stdout=None, stderr=None, env=None):
    r = subprocess.run([str(x) for x in command], cwd=ROOT, capture_output=True, text=True,
                       timeout=120, env=env)
    if r.returncode != expected or (stdout is not None and r.stdout != stdout) or (stderr and stderr not in r.stderr):
        raise RuntimeError(f"{command}: exit {r.returncode}\n{r.stdout}{r.stderr}")
    return r.stdout


def link(source, binary, llvm=False, fake=False):
    flags = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
    sources = [source, *rt_src()]
    if llvm:
        sources.extend(rt_llvm())
    if fake:
        flags += ["-Dclock_gettime=orin_test_clock_gettime", "-DCLOCK_STUB_ONLY", "-ftrivial-auto-var-init=pattern"]
        sources.append("runtime/core/tests/clock_test.c")
    run(["clang", "-O1", "-g", *flags, *rt_inc(), *sources, "-lm", "-o", binary])



def check_effects_report(report):
    entry = report.get("entry", {})
    matches = [effect for effect in entry.get("effects", [])
               if (effect.get("operation"), effect.get("direction"), effect.get("grant"), effect.get("evidence"))
               == ("Clock.Now", "INPUT", "ClockGrant", "MAY")]
    if report.get("schema") != "effects/0.1" or report.get("typed") is not True or len(matches) != 1:
        raise RuntimeError("missing entry Clock.Now/ClockGrant effect: " + json.dumps(entry))
    path = matches[0].get("path", [])
    if ([step.get("function") for step in path] != [entry.get("function"), "std:time::monotonicNow"]
            or path[-1].get("route") != "io" or path[-1].get("span", {}).get("file") != "$stdlib/time.or"):
        raise RuntimeError("clock effect does not trace through monotonicNow: " + json.dumps(matches[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orinc", default="build/bootstrap/orin2")
    args = parser.parse_args()
    compiler = (ROOT / args.orinc).resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k != "ORIN_DENY"}
    env["ASAN_OPTIONS"] = "detect_leaks=0"
    native = OUT / "native"
    run(["clang", "-O1", "-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
         "-ftrivial-auto-var-init=pattern", "-Dclock_gettime=orin_test_clock_gettime", *rt_inc(),
         "runtime/core/tests/clock_test.c", *rt_src(), "-lm", "-o", native])
    run([native, "platform"], stdout="platform clock cases passed\n", env=env)
    run([native], stdout="clock failure returned None\n", env=env)
    run([native, "wrong"], expected=101, stderr="invalid capability grant", env=env)
    run([native, "revoked"], expected=101, stderr="invalid capability grant", env=env)
    run([native, "net"], expected=101, stderr="monotonic clock unavailable", env=env)
    run([native], expected=101, stderr="capability denied: clock monotonicMillis", env={**env, "ORIN_DENY": "clock"})
    print("PASS native failure/zero/negative/nsec/overflow/boundary and grant/network cases", flush=True)
    failure = OUT / "failure.or"
    failure.write_text('''import { Host, useClock } from "std:host";
import { monotonicNow, timeErrorMessage } from "std:time";
import { assert, assertEqString } from "std:test";
function main(host: Host): void {
  useClock(host, clock => {
    const r = monotonicNow(clock);
    assert(r.isErr(), "failed read must be an ordinary error");
    assertEqString(timeErrorMessage(r.unwrapErr()), "monotonic clock unavailable", "stable error");
    console.log("clock failure handled");
  });
}
''')
    for backend in ("c", "llvm"):
        for contracts in (False, True):
            suffix = backend + ("-checked" if contracts else "-plain")
            flags = ["--backend=" + backend] + (["--check-contracts"] if contracts else [])
            for label, entry, fake, expected in [
                ("normal", "tests/next/run/std_time_monotonic.or", False, "monotonic clock passed\n"),
                ("failure", failure, True, "clock failure handled\n"),
            ]:
                generated = OUT / (label + suffix + (".ll" if backend == "llvm" else ".c"))
                binary = OUT / (label + suffix)
                run([compiler, "compile", entry, *flags, "-o", generated])
                link(generated, binary, backend == "llvm", fake)
                run([binary], stdout=expected, env=env)
                run([binary], expected=101, stderr="capability denied: clock monotonicMillis", env={**env, "ORIN_DENY": "clock"})
            print(f"PASS {backend} contracts={contracts}: arithmetic, real reads, injected failure, denied grant (ASan/UBSan)", flush=True)
    effects = json.loads(run([compiler, "effects", "tests/next/run/std_time_monotonic.or", "--format=json"]))
    check_effects_report(effects)
    run([compiler, "effects", "tests/next/run/std_time_monotonic.or", "--check-purity"])
    print("PASS clock effects and purity agreement", flush=True)


if __name__ == "__main__":
    main()
