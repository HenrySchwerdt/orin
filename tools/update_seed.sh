#!/bin/sh
# Regenerate seed/ from the current compiler/ (ADR-0014).
#   tools/update_seed.sh                 bootstrap from the current seed
# The new seed is stage2.c, i.e. the C of the compiler as compiled by a compiler built from the
# *previous* root. Commit the result in a PR that shows the full bootstrap from the old seed.
set -eu
cd "$(dirname "$0")/.."
SEED=seed
B=build/bootstrap
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
prev=$(sed -n 's/^source-commit: *//p' $SEED/SEED_INFO | head -n1)
how="previous seed (source commit ${prev:-unknown}) via tools/bootstrap.sh"
./tools/bootstrap.sh
mkdir -p $SEED
gzip -9n -c $B/stage2.c > $SEED/orin-seed.c.gz
cat > $SEED/SEED_INFO <<INFO
source-commit: $(git rev-parse HEAD)
sha256: $(sha256 $B/stage2.c)
size: $(wc -c < $B/stage2.c)
produced-by: $how
date: $(date -u +%Y-%m-%d)
INFO
if [ -n "$(git status --porcelain -- compiler runtime platform std)" ]; then
  echo "note: uncommitted changes in compiler/runtime/platform/std; source-commit is only HEAD" >&2
fi
echo "seed written: $SEED/orin-seed.c.gz ($(wc -c < $SEED/orin-seed.c.gz) bytes)"
