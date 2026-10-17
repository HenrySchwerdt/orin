#!/bin/sh
# ADR-0052 Addendum A section 4: the frozen runtime snapshot bootstrap/seed/runtime/ (world `legacy` of tools/runtime-sources.txt)
# must define every external symbol the live runtime (world `core`) defines, except the ones listed in
# bootstrap/seed/runtime/core-only-symbols.txt (R3d additions the legacy world never references). A new C interface outside the
# object model (task, monitor, capability, network functions) is copied verbatim into the snapshot in the same PR; this check
# says so before the --c-builtins differential fails with undefined references.
#   tools/check_seed_runtime.sh
set -eu
cd "$(dirname "$0")/.."
. tools/runtime_files.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/seedrt.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
CC=${CC:-cc}
symbols() {   # world -> sorted external symbols defined by its runtime/core (or snapshot) C files
  world=$1; inc=$(rt_inc "$world")
  for f in $(rt_src "$world") $(rt_llvm "$world"); do
    case "$f" in runtime/platform/*) continue ;; esac
    # shellcheck disable=SC2086
    $CC -c -O1 -w $inc -I runtime/platform "$f" -o "$tmp/$world-$(basename "$f" .c).o"
  done
  nm -g --defined-only "$tmp/$world"-*.o | awk 'NF == 3 { print $3 }' | sort -u
}
symbols core > "$tmp/core.txt"
symbols legacy > "$tmp/legacy.txt"
grep -v '^#' bootstrap/seed/runtime/core-only-symbols.txt | sed '/^$/d' | sort -u > "$tmp/allowed.txt"
missing=$(comm -23 "$tmp/core.txt" "$tmp/legacy.txt" | comm -23 - "$tmp/allowed.txt")
if [ -n "$missing" ]; then
  echo "check_seed_runtime: the live runtime defines symbols the frozen snapshot bootstrap/seed/runtime/ lacks:" >&2
  echo "$missing" | sed 's/^/  /' >&2
  echo "Copy them verbatim into bootstrap/seed/runtime/orin_runtime.{c,h} (see its README), or, if only R3d code in \$rt uses" >&2
  echo "them, list them in bootstrap/seed/runtime/core-only-symbols.txt." >&2
  exit 1
fi
echo "check_seed_runtime: ok ($(wc -l < "$tmp/core.txt") live symbols, all in the snapshot or core-only)"
