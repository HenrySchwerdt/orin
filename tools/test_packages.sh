#!/bin/sh
# Package tests (spec 04, ADR-0016) with the self-hosted compiler: package-directory arguments,
# default layout (src/main.or), `orin check --deps`, `orin api` / `orin api --check`, enforcement
# of allowed_dependencies on a modified copy, and the dist/orin launcher (build/run a directory).
# The multi-file run/error tests live in tests/next (run by tools/run_tests.py).
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
SHOP=tests/next/packages/shop
T=build/pkgtest
rm -rf "$T"
mkdir -p "$T"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 1. package directory: check, compile, run
$ORIN2 check "$SHOP" && ok "check <package-dir>" || bad "check <package-dir>"
$ORIN2 compile "$SHOP" -o "$T/shop.c"
cc -O1 -w -I runtime "$T/shop.c" runtime/orin_runtime.c platform/orin_platform.c -lm -o "$T/shop-exe"
got=$("$T/shop-exe")
want=$(printf 'user 7 bob (internal)\n332')
[ "$got" = "$want" ] && ok "compile+run <package-dir>" || bad "compile+run <package-dir> (got: $got)"
$ORIN2 check "$SHOP/src/main.or" && ok "check entry file inside the package" || bad "check entry file inside the package"

# 2. dependency summary (text and JSON) against goldens
$ORIN2 check --deps "$SHOP" > "$T/deps.txt"
diff -u tests/next/packages/shop.deps.txt "$T/deps.txt" && ok "check --deps (text)" || bad "check --deps (text)"
$ORIN2 check --deps --format=json "$SHOP" > "$T/deps.json"
diff -u tests/next/packages/shop.deps.json "$T/deps.json" && ok "check --deps --format=json" || bad "check --deps --format=json"

# 3. API snapshot: deterministic, unchanged vs golden, change detection
$ORIN2 api "$SHOP" > "$T/api1.txt"
$ORIN2 api "$SHOP/src/main.or" > "$T/api2.txt"
cmp -s "$T/api1.txt" "$T/api2.txt" && ok "api: same for directory and entry file" || bad "api: directory vs entry file"
diff -u tests/next/packages/shop.api.txt "$T/api1.txt" && ok "api snapshot matches golden" || bad "api snapshot matches golden"
$ORIN2 api --check tests/next/packages/shop.api.txt "$SHOP" > "$T/chk.out" 2>&1 && ok "api --check unchanged (exit 0)" || bad "api --check unchanged"

cp -r "$SHOP" "$T/shop2"
# a new exported function and a method that stopped mutating
printf 'export function extra(): int { return 1; }\n' >> "$T/shop2/src/database/table.or"
printf 'export { Table, openTable, extra } from "./table";\n' > "$T/shop2/src/database/module.or"
sed -i '/this.rows = 0;/d' "$T/shop2/src/database/table.or"
if $ORIN2 api --check tests/next/packages/shop.api.txt "$T/shop2" > "$T/chk2.out" 2>&1; then
  bad "api --check must exit 1 when the API changed"
else
  grep -q '^+   function extra' "$T/chk2.out" && grep -q '^+     method reset' "$T/chk2.out" \
    && grep -q '^-     mut method reset' "$T/chk2.out" \
    && ok "api --check detects added export and inferred mutability change (exit 1)" \
    || { bad "api --check diff content"; cat "$T/chk2.out"; }
fi
# a private (non-exported) change is not an API change
cp -r "$SHOP" "$T/shop3"
printf '\nfunction privateHelper(): int { return 9; }\n' >> "$T/shop3/src/users/internal.or"
$ORIN2 api --check tests/next/packages/shop.api.txt "$T/shop3" > /dev/null 2>&1 && ok "api --check ignores private changes" || bad "api --check ignores private changes"

# 4. enforcement: users may only import database
cp -r "$SHOP" "$T/shop4"
sed -i 's|^import { hidden }|import { charge } from "../payments";\nimport { hidden }|' "$T/shop4/src/users/user.or"
if $ORIN2 check "$T/shop4" > "$T/e501.out" 2>&1; then
  bad "E0501 expected"
else
  grep -q 'E0501' "$T/e501.out" && grep -q 'allowed_dependencies' "$T/e501.out" && ok "E0501 on disallowed dependency (names the rule)" || { bad "E0501 text"; cat "$T/e501.out"; }
fi
if $ORIN2 check --format=json "$T/shop4" > "$T/e501.json" 2>&1; then bad "E0501 json"; else
  grep -q '"E0501"' "$T/e501.json" && ok "E0501 in --format=json" || { bad "E0501 json content"; cat "$T/e501.json"; }
fi
# unknown module / manifest syntax error
cp -r "$SHOP" "$T/shop5"
printf '\n[modules.ghost]\nallowed_dependencies = []\n' >> "$T/shop5/orin.toml"
$ORIN2 check "$T/shop5" 2>&1 | grep -q E0502 && ok "E0502 unknown module" || bad "E0502 unknown module"
cp -r "$SHOP" "$T/shop6"
printf '\n[modules.users\n' >> "$T/shop6/orin.toml"
$ORIN2 check "$T/shop6" 2>&1 | grep -q 'orin.toml:[0-9]*:[0-9]*: error\[E0500\]' && ok "E0500 manifest syntax error with line" || bad "E0500 manifest syntax error"

# 5. launcher: orin build / orin run with a package directory
D="$T/dist"
mkdir -p "$D/bin" "$D/libexec" "$D/lib/orin"
cp dist/orin "$D/bin/orin"
cp "$ORIN2" "$D/libexec/orin"
cp -r runtime "$D/lib/orin/runtime"
cp -r platform "$D/lib/orin/platform"
echo 0.0.0-test > "$D/VERSION"
(cd "$T" && "dist/bin/orin" build "../../$SHOP" -o shop-built)
got=$("$T/shop-built")
[ "$got" = "$want" ] && ok "launcher: orin build <package-dir>" || bad "launcher: orin build <package-dir>"
got=$("$D/bin/orin" run "$SHOP")
[ "$got" = "$want" ] && ok "launcher: orin run <package-dir>" || bad "launcher: orin run <package-dir>"
(cd "$T" && "dist/bin/orin" build "../../$SHOP") && [ -x "$T/shop" ] && ok "launcher: default output name is the directory name" || bad "launcher: default output name"

[ "$fail" = 0 ] && echo "packages: all ok" || { echo "packages: FAILED"; exit 1; }
