#!/bin/sh
# Test install.sh and `orin doctor` against a release tarball built by tools/package.sh.
#   tools/test_install.sh build/dist/orin-<version>-<platform>.tar.gz
# Everything happens under a temp dir (HOME, ORIN_HOME and the release "server" are all local; no network).
# Needs a C compiler for the end-to-end steps (the package smoke test needs one as well).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ $# -eq 1 ] || { echo "usage: $0 <orin-version-platform.tar.gz>" >&2; exit 2; }
TARBALL=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
[ -f "$TARBALL" ] || { echo "no such tarball: $1" >&2; exit 2; }
INSTALL=$ROOT/install.sh
FNAME=$(basename "$TARBALL")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM

pass=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/       /' >&2; exit 1; }

# Run install.sh with an isolated HOME. Extra env assignments come as arguments.
run_install() { # run_install <env...> -- <args...>
  envs=; while [ "$1" != -- ]; do envs="$envs $1"; shift; done; shift
  # shellcheck disable=SC2086
  env -i PATH="$PATH" HOME="$T/home" TERM=dumb $envs sh "$INSTALL" "$@"
}
mkdir -p "$T/home"

mkdir "$T/peek"; tar -xzf "$TARBALL" -C "$T/peek"
WANT=$(cat "$T"/peek/*/VERSION | tr -d '\n'); rm -rf "$T/peek"
[ -n "$WANT" ] || fail "tarball has no VERSION"
echo "install tests with $FNAME (version $WANT)"

# 1. syntax
sh -n "$INSTALL" || fail "sh -n install.sh"
sh -n "$ROOT/dist/orin" || fail "sh -n dist/orin"
ok "syntax"

# 2. platform detection
plat=$(sh "$INSTALL" --print-platform)
case $plat in linux-x86_64|linux-aarch64|macos-arm64|macos-x86_64) ok "platform detected: $plat" ;; *) fail "platform: $plat" ;; esac
[ "$(ORIN_PLATFORM=macos-arm64 sh "$INSTALL" --print-platform)" = macos-arm64 ] || fail "ORIN_PLATFORM override"
if out=$(ORIN_PLATFORM=plan9-mips ORIN_VERSION=0.0.1 ORIN_BASE_URL=file:///nonexistent sh "$INSTALL" 2>&1); then fail "unsupported platform must fail"; fi
case $out in *"no release package for platform"*) ok "unsupported platform is rejected" ;; *) fail "unsupported platform message" "$out" ;; esac

# 3. local tarball + checksum sidecar; installs, links, runs (through the symlink)
cp "$TARBALL" "$T/local.tar.gz"
[ -f "$TARBALL.sha256" ] || fail "no $FNAME.sha256 beside the tarball (tools/package.sh writes it)"
sed "s/  .*/  local.tar.gz/" "$TARBALL.sha256" > "$T/local.tar.gz.sha256"
H=$T/orin-home; B=$T/bin
out=$(run_install ORIN_HOME="$H" ORIN_BIN_DIR="$B" ORIN_INSTALL_FROM="$T/local.tar.gz" -- ) || fail "local install" "$out"
case $out in *"sha256 verified"*) ok "local install verified the sidecar checksum" ;; *) fail "no checksum verification in local install" "$out" ;; esac
[ -f "$H/.orin-install" ] && [ -x "$H/bin/orin" ] && [ -h "$B/orin" ] || fail "install layout"
[ "$("$B/orin" --version)" = "$WANT" ] || fail "orin --version through the symlink"
ok "orin --version through two symlinks = $WANT"
hello=$("$B/orin" run "$H/current/examples/hello.or") || fail "hello via symlink"
[ "$hello" = "Hello from Orin!" ] || fail "hello output" "$hello"
ok "orin run hello via symlink"
out=$(env HOME="$T/home" PATH="$B:$PATH" orin doctor 2>&1) || fail "orin doctor" "$out"
case $out in *"All good."*) ok "orin doctor: all good" ;; *) fail "doctor output" "$out" ;; esac

# 4. upgrade/reinstall is idempotent
run_install ORIN_HOME="$H" ORIN_BIN_DIR="$B" ORIN_INSTALL_FROM="$T/local.tar.gz" -- >/dev/null 2>&1 || fail "reinstall"
[ "$(ls "$H/versions" | wc -l | tr -d ' ')" = 1 ] || fail "old versions are not pruned"
ok "reinstall keeps one version"

# 5. tampered tarball with the original checksum: fail closed, nothing installed
cp "$TARBALL" "$T/bad.tar.gz"; printf 'x' >> "$T/bad.tar.gz"
sed "s/  .*/  bad.tar.gz/" "$T/local.tar.gz.sha256" > "$T/bad.tar.gz.sha256"
if out=$(run_install ORIN_HOME="$T/h2" ORIN_BIN_DIR="$T/b2" ORIN_INSTALL_FROM="$T/bad.tar.gz" -- 2>&1); then fail "tampered tarball was installed"; fi
case $out in *"sha256 mismatch"*) ;; *) fail "mismatch message" "$out" ;; esac
[ ! -e "$T/h2" ] && [ ! -e "$T/b2" ] || fail "mismatch left files behind"
ok "checksum mismatch fails closed, nothing installed"

# 6. fake release server (file://): latest-by-pin, SHA256SUMS lookup, mismatch, missing entry
case $FNAME in
  orin-"$WANT"-"$plat".tar.gz)
    REL=$T/rel/v$WANT; mkdir -p "$REL"
    cp "$TARBALL" "$REL/$FNAME"
    ( cd "$REL" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$FNAME"; else shasum -a 256 "$FNAME"; fi > SHA256SUMS )
    URL=file://$T/rel
    out=$(run_install ORIN_HOME="$T/h3" ORIN_BIN_DIR="$T/b3" ORIN_BASE_URL="$URL" ORIN_VERSION="$WANT" -- 2>&1) || fail "download install" "$out"
    [ "$("$T/b3/orin" --version)" = "$WANT" ] || fail "downloaded install version"
    ok "download + SHA256SUMS verification (ORIN_VERSION=$WANT)"
    out=$(run_install ORIN_HOME="$T/h3" ORIN_BIN_DIR="$T/b3" ORIN_BASE_URL="$URL" ORIN_VERSION="v$WANT" -- 2>&1) || fail "v-prefixed pin" "$out"
    ok "ORIN_VERSION accepts a leading v"
    sed 's/^./0/' "$REL/SHA256SUMS" > "$REL/SHA256SUMS.bad"; mv "$REL/SHA256SUMS.bad" "$REL/SHA256SUMS"
    if out=$(run_install ORIN_HOME="$T/h4" ORIN_BIN_DIR="$T/b4" ORIN_BASE_URL="$URL" ORIN_VERSION="$WANT" -- 2>&1); then fail "wrong SHA256SUMS accepted"; fi
    case $out in *"sha256 mismatch"*) ;; *) fail "SHA256SUMS mismatch message" "$out" ;; esac
    [ ! -e "$T/h4" ] || fail "mismatch left files behind (download)"
    : > "$REL/SHA256SUMS"
    if out=$(run_install ORIN_HOME="$T/h4" ORIN_BIN_DIR="$T/b4" ORIN_BASE_URL="$URL" ORIN_VERSION="$WANT" -- 2>&1); then fail "missing checksum entry accepted"; fi
    case $out in *"no entry"*) ok "wrong or missing SHA256SUMS entry fails closed" ;; *) fail "missing entry message" "$out" ;; esac
    rm -f "$REL/SHA256SUMS"
    if run_install ORIN_HOME="$T/h4" ORIN_BIN_DIR="$T/b4" ORIN_BASE_URL="$URL" ORIN_VERSION="$WANT" -- >/dev/null 2>&1; then fail "missing SHA256SUMS accepted"; fi
    ok "missing SHA256SUMS fails closed"
    ;;
  *) echo "  skip download tests (tarball name does not match host platform $plat)" ;;
esac

# 7. refuses to use a foreign directory as ORIN_HOME
mkdir -p "$T/foreign"; : > "$T/foreign/precious"
if run_install ORIN_HOME="$T/foreign" ORIN_BIN_DIR="$T/b5" ORIN_INSTALL_FROM="$T/local.tar.gz" -- >/dev/null 2>&1; then fail "installed into a foreign dir"; fi
[ -f "$T/foreign/precious" ] || fail "foreign dir damaged"
if run_install ORIN_HOME="$T/foreign" -- --uninstall >/dev/null 2>&1; then fail "uninstall removed a foreign dir"; fi
[ -f "$T/foreign/precious" ] || fail "uninstall damaged a foreign dir"
ok "foreign ORIN_HOME is refused (install and uninstall)"

# 8. no compiler: install still succeeds, prints a hint; doctor fails with a fix
out=$(run_install ORIN_HOME="$T/h6" ORIN_BIN_DIR="$T/b6" ORIN_INSTALL_FROM="$T/local.tar.gz" CC=orin-no-such-cc -- 2>&1) || fail "install without compiler" "$out"
case $out in *"no C compiler"*) ;; *) fail "no compiler hint" "$out" ;; esac
case $out in *"apt-get"*|*"dnf"*|*"pacman"*|*"apk"*|*"zypper"*|*"xcode-select"*|*"install gcc or clang"*) ok "missing compiler: install warns with a hint" ;; *) fail "hint text" "$out" ;; esac
if out=$(CC=orin-no-such-cc "$T/b6/orin" doctor 2>&1); then fail "doctor must fail without a compiler" "$out"; fi
case $out in *"[FAIL] C compiler"*"fix:"*) ok "orin doctor fails with an actionable fix when the compiler is missing" ;; *) fail "doctor fail output" "$out" ;; esac

# 9. doctor: broken layout
cp -R "$H/current" "$T/broken"; rm -rf "$T/broken/lib"
if out=$("$T/broken/bin/orin" doctor 2>&1); then fail "doctor must fail on a broken layout" "$out"; fi
case $out in *"install layout: missing"*) ok "orin doctor detects a broken layout" ;; *) fail "layout message" "$out" ;; esac

# 10. doctor: orin not on PATH is a warning with the export line
out=$(env -i PATH="$(dirname "$(command -v cc)"):/usr/bin:/bin" HOME="$T/home" "$H/bin/orin" doctor 2>&1) || fail "doctor with orin off PATH" "$out"
case $out in *"[warn] PATH"*"export PATH="*) ok "orin doctor explains PATH when orin is not on it" ;; *) fail "PATH warning" "$out" ;; esac

# 11. uninstall
out=$(run_install ORIN_HOME="$H" ORIN_BIN_DIR="$B" -- --uninstall 2>&1) || fail "uninstall" "$out"
[ ! -e "$H" ] && [ ! -e "$B/orin" ] || fail "uninstall left files"
run_install ORIN_HOME="$H" ORIN_BIN_DIR="$B" -- --uninstall >/dev/null 2>&1 || fail "second uninstall must be a no-op"
ok "uninstall removes the install and the symlink (idempotent)"

echo "install tests: $pass checks passed"
