"""The runtime source list for Python tools (ADR-0052 Addendum A section 4). The data is tools/runtime-sources.txt.

    from runtime_files import rt_inc, rt_src, rt_llvm
    cmd = ["cc", "-O1", "-w"] + rt_inc() + [c] + rt_src() + ["-lm", "-o", exe]

world: "core" (default, the live runtime) or "legacy" (the frozen snapshot bootstrap/seed/runtime/). Paths are relative to the
repository root, the working directory of the tools.
"""
import os

_LIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "runtime-sources.txt")


def _get(key):
    with open(_LIST, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == key:
                return v.split()
    raise KeyError(key)


def rt_inc(world="core"):
    out = []
    for d in _get(world + ".include"):
        out += ["-I", d]
    return out


def rt_src(world="core"):
    return _get(world + ".sources")


def rt_llvm(world="core"):
    return _get(world + ".llvm")
