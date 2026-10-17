#!/bin/sh
# Regenerate bootstrap/seed/ from the current compiler/ (ADR-0014).
#   tools/update_seed.sh                 bootstrap from the current seed
# The new seed is the C of the compiler (orin2 compile --c-builtins), as compiled by a compiler built from the
# *previous* root. Commit the result in a PR that shows the full bootstrap from the old seed.
set -eu
cd "$(dirname "$0")/.."
SEED=bootstrap/seed
B=build/bootstrap
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
prev=$(sed -n 's/^source-commit: *//p' $SEED/SEED_INFO | head -n1)
how="previous seed (source commit ${prev:-unknown}) via tools/bootstrap.sh"
./tools/bootstrap.sh
mkdir -p $SEED
# The seed is the C runtime path build (--c-builtins): stage 0 and stage 1 link the frozen runtime snapshot.
$B/orin2 compile --c-builtins compiler/main.or -o $B/seed-new.c
gzip -9n -c $B/seed-new.c > $SEED/orin-seed.c.gz
cat > $SEED/SEED_INFO <<INFO
source-commit: $(git rev-parse HEAD)
sha256: $(sha256 $B/seed-new.c)
size: $(wc -c < $B/seed-new.c)
produced-by: $how
date: $(date -u +%Y-%m-%d)
INFO
if [ -n "$(git status --porcelain -- compiler runtime library)" ]; then
  echo "note: uncommitted changes in compiler/runtime/library; source-commit is only HEAD" >&2
fi
echo "seed written: $SEED/orin-seed.c.gz ($(wc -c < $SEED/orin-seed.c.gz) bytes)"
