# API snapshots of the standard library

`api/std/<module>.api.txt` is the committed public API of each public std module (`std:bytes` is `api/std/bytes.api.txt`,
`std:json/number` is `api/std/json/number.api.txt`). It is the `orin-api 1` format of `orin api` (the same format as
`tests/next/packages/shop.api.txt`): one block per exported declaration with its full signature, annotations (contracts) and
members. `api/MODULES` lists the modules and marks each `frozen`, `experimental` or `builtin`.
This is criterion C11 of [ADR-0056](decisions/0056-syntax-and-std-freeze.md) (section 3).

## Checking and updating

```
python3 tools/check_api_snapshots.py                 # CI: regenerate, diff, exit 1 on any difference
python3 tools/check_api_snapshots.py --update        # rewrite api/std/*.api.txt after an intended change
python3 tools/check_api_snapshots.py --list          # modules and their stability
```

The compiler is `build/bootstrap/orin2` (`--orin <path>` or `$ORIN` to change it). CI runs the check in the job that
builds `orin2`. A new public std module (a new entry in `compiler/loader/resolve.or`) fails the check until it is added to
`api/MODULES` and its snapshot is created with `--update`.

## How it works

`orin api` snapshots a program (it needs `main`), and a std module is not a program. For each module the script writes a
throw-away entry that re-exports every exported name of the module and has an empty `main`, runs `orin api` on it and renames
`module (root)` to `module std:<name>`. The exported names are read from the module source (`library/std/*.or`,
`library/collections/math.or`), including names the module re-exports from other units. This needs no compiler change; a
future `orin api --std <module>` (ADR-0056 section 3) would replace the wrapper and produce the same text. The script fails
when a name it asked for is missing from the output (`orin api` drops unresolved names silently).

Limits: names re-exported from a loader built-in (`std:fsraw`, `std:clock`: `File`, `FsGrant`, `Host`, `NetGrant`,
`readBytes`, `ClockGrant`, ...) have no source unit, so they appear as `builtin <name> from <module>` lines without a
signature. `std:process` is a loader built-in with no source file and has no snapshot. The preludes (`library/core`,
`library/collections` methods on array, map and string) are not covered yet.

## Policy

- **Frozen modules.** A snapshot change is a public API change. After the freeze it needs an ADR or a `changes/` fragment that
  says whether the change is additive (only added lines) or breaking (removed or changed lines); breaking changes are only for
  a major version. `std:json/legacy` is frozen but deprecated: it changes only by removal in a major version.
- **Experimental modules** (`std:meta`, `std:html`, `std:ox`, `std:task`; ADR-0056 section 1.2, [stability.md](stability.md)).
  The snapshot is kept so changes are visible, but they are allowed: update it with `--update` and mention it in the `changes/`
  fragment. `std:task` is frozen for the Gate 1 API only; the whole module is marked experimental so additions beyond Gate 1
  are free, but a removed or changed Gate 1 name is a breaking change.
- `std:fs`, `std:host`, `std:io`, `std:time`, `std:net` are snapshotted as frozen; they become binding when criterion C5 is met.
- Internal modules (`taskcore`, `metacore`, `metajson`, `fsraw`, `clock`, `core`, `*/internal`) have no snapshot.
