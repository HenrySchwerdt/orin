#!/usr/bin/env bash
# CI check for the formal memory-safety model: builds everything and rejects any escape hatch.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.elan/bin:$PATH"

echo "== lake build"
lake build

echo "== scanning sources for escape hatches"
if grep -nE '\b(sorry|admit|axiom|native_decide|unsafe|opaque|implemented_by|extern)\b' Orin.lean Orin/*.lean \
     | grep -v '^Orin/Audit.lean' | grep -vE '^[^:]+:[0-9]+:\s*(--|/-)'; then
  echo "FAIL: forbidden construct found in sources" >&2
  exit 1
fi

echo "== axiom audit"
out="$(lake env lean Orin/Audit.lean)"
echo "$out"
if echo "$out" | grep -q sorryAx; then
  echo "FAIL: a theorem depends on sorryAx" >&2
  exit 1
fi
if echo "$out" | grep -oE "\[[^]]*\]" | tr -d '[]' | tr ',' '\n' | sed 's/^ *//' \
     | grep -vE '^(propext|Classical.choice|Quot.sound)?$' | grep -q .; then
  echo "FAIL: non-standard axiom used" >&2
  exit 1
fi
echo "OK: formal model builds; no sorry/admit/axiom; only standard axioms."
