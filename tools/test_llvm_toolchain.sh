#!/bin/sh
# `orin toolchain` (ADR-0038 section 8, gate 3) against a local fake LLVM archive; needs no network.
#   tools/test_llvm_toolchain.sh
# 1. dist/llvm.pin is well formed (version, one https asset with a 64-digit sha256 per platform, version in the URL).
# 2. install: the archive is verified by sha256 before anything is unpacked; a wrong checksum, a missing platform or an archive
#    whose clang reports another version installs nothing; a good archive lands in $ORIN_HOME/toolchains/llvm-<version>.
# The fake archive is served with file:// URLs, so the real download path (curl) runs.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# ---- 1. the real pin ---------------------------------------------------------------------------------------------
PIN=$ROOT/dist/llvm.pin
ver=$(awk '$1 == "version" { print $2 }' "$PIN")
case $ver in [0-9]*.[0-9]*.[0-9]*) ;; *) fail "dist/llvm.pin: bad version '$ver'" ;; esac
[ "$(awk '$1 == "version"' "$PIN" | wc -l)" -eq 1 ] || fail "dist/llvm.pin: exactly one version line expected"
n=0
while read -r kw plat sum url rest; do
  [ "$kw" = asset ] || continue
  n=$((n + 1))
  [ -z "$rest" ] || fail "dist/llvm.pin: trailing text on the $plat line"
  case $plat in linux-x86_64|linux-aarch64|macos-arm64|macos-x86_64) ;; *) fail "dist/llvm.pin: unknown platform $plat" ;; esac
  [ "${#sum}" -eq 64 ] && [ -z "$(printf '%s' "$sum" | tr -d '0-9a-f')" ] || fail "dist/llvm.pin: $plat: sha256 is not 64 hex digits"
  case $url in https://*"$ver"*) ;; *) fail "dist/llvm.pin: $plat: url must be https and name version $ver" ;; esac
done < "$PIN"
[ "$n" -ge 3 ] || fail "dist/llvm.pin: expected at least linux-x86_64, linux-aarch64 and macos-arm64"
grep -q '^asset linux-x86_64 ' "$PIN" && grep -q '^asset linux-aarch64 ' "$PIN" && grep -q '^asset macos-arm64 ' "$PIN" || fail "dist/llvm.pin: a supported platform is missing"
ok "dist/llvm.pin: LLVM $ver, $n platforms"

# ---- 2. install against a fake archive ---------------------------------------------------------------------------
PKG=$T/pkg
mkdir -p "$PKG/bin" "$PKG/lib/orin"
cp dist/orin "$PKG/bin/orin"
ORIN=$PKG/bin/orin

make_archive() { # make_archive <version-reported-by-clang> <out>
  d=$T/src-$1; rm -rf "$d"; mkdir -p "$d/clang+llvm-fake/bin"
  printf '#!/bin/sh\necho "clang version %s (fake)"\n' "$1" > "$d/clang+llvm-fake/bin/clang"
  cp "$d/clang+llvm-fake/bin/clang" "$d/clang+llvm-fake/bin/llc"
  chmod +x "$d/clang+llvm-fake/bin/clang" "$d/clang+llvm-fake/bin/llc"
  mkdir -p "$d/clang+llvm-fake/lib/clang/19/include"; : > "$d/clang+llvm-fake/lib/clang/19/include/stddef.h"; : > "$d/clang+llvm-fake/bin/clang-19"
  tar -czf "$2" -C "$d" clang+llvm-fake
}
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }
write_pin() { # write_pin <version> <sha256> <archive>
  printf 'version %s\nasset linux-x86_64 %s file://%s\n' "$1" "$2" "$3" > "$PKG/lib/orin/llvm.pin"
}
run() { env -i PATH="$PATH" HOME="$T/home" ORIN_HOME="$T/home/.orin" ORIN_PLATFORM=linux-x86_64 sh "$ORIN" toolchain "$@"; }

make_archive 19.1.7 "$T/good.tar.gz"
make_archive 18.1.8 "$T/wrongver.tar.gz"
GOOD=$(sha_of "$T/good.tar.gz")
DEST=$T/home/.orin/toolchains/llvm-19.1.7

# not installed yet
write_pin 19.1.7 "$GOOD" "$T/good.tar.gz"
run path >/dev/null 2>&1 && fail "path succeeded before install"
run status >"$T/out" 2>&1 && fail "status succeeded before install"
grep -q 'installed:   no' "$T/out" || fail "status does not say not installed"
[ "$(run version)" = 19.1.7 ] || fail "version"
ok "status before install"

# a wrong checksum installs nothing
write_pin 19.1.7 0000000000000000000000000000000000000000000000000000000000000000 "$T/good.tar.gz"
run install >"$T/out" 2>&1 && fail "install accepted a wrong checksum"
grep -q 'sha256 mismatch' "$T/out" || fail "no mismatch message: $(cat "$T/out")"
[ ! -e "$DEST" ] || fail "a rejected archive was installed"
[ -z "$(ls -A "$T/home/.orin/toolchains")" ] || fail "temporary files left behind: $(ls -A "$T/home/.orin/toolchains")"
ok "wrong checksum rejected, nothing installed"

# a tampered archive (the pin has the checksum of the good one) is rejected
cp "$T/good.tar.gz" "$T/tampered.tar.gz"; printf 'x' >> "$T/tampered.tar.gz"
write_pin 19.1.7 "$GOOD" "$T/tampered.tar.gz"
run install >"$T/out" 2>&1 && fail "install accepted a tampered archive"
[ ! -e "$DEST" ] || fail "a tampered archive was installed"
ok "tampered archive rejected"

# the archive's clang must report the pinned version
write_pin 19.1.7 "$(sha_of "$T/wrongver.tar.gz")" "$T/wrongver.tar.gz"
run install >"$T/out" 2>&1 && fail "install accepted a clang of another version"
grep -q 'does not report version 19.1.7' "$T/out" || fail "no version message: $(cat "$T/out")"
[ ! -e "$DEST" ] || fail "a wrong-version archive was installed"
ok "wrong clang version rejected"

# a platform without a pinned archive
write_pin 19.1.7 "$GOOD" "$T/good.tar.gz"
env -i PATH="$PATH" HOME="$T/home" ORIN_HOME="$T/home/.orin" ORIN_PLATFORM=macos-x86_64 sh "$ORIN" toolchain install >"$T/out" 2>&1 && fail "install worked on an unpinned platform"
grep -q "no LLVM 19.1.7 archive for platform 'macos-x86_64'" "$T/out" || fail "no platform message: $(cat "$T/out")"
ok "unpinned platform refused"

# the good archive
run install >"$T/out" 2>&1 || fail "install failed: $(cat "$T/out")"
grep -q 'sha256 verified' "$T/out" || fail "no verification line"
[ -x "$DEST/bin/clang" ] || fail "clang not installed"
[ "$(run path)" = "$DEST/bin/clang" ] || fail "path: $(run path)"
run status | grep -q 'installed:   yes' || fail "status after install"
grep -q "^sha256 $GOOD\$" "$DEST/.orin-toolchain" || fail "marker lacks the checksum"
[ -z "$(ls -A "$T/home/.orin/toolchains" | grep '^\.install')" ] || fail "temporary files left behind"
ok "install"

# idempotent; --force reinstalls
run install | grep -q 'already installed' || fail "second install was not a no-op"
echo stale > "$DEST/stale"
run install --force >/dev/null 2>&1 || fail "install --force failed"
[ ! -e "$DEST/stale" ] || fail "--force kept the old tree"
ok "second install is a no-op, --force reinstalls"

# a different pinned version is not "installed"
write_pin 19.1.8 "$GOOD" "$T/good.tar.gz"
run path >/dev/null 2>&1 && fail "path reported a toolchain of another version"
ok "an installed toolchain of another version does not match the pin"

echo "all LLVM toolchain tests passed"
