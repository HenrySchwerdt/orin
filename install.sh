#!/bin/sh
# Orin installer (POSIX sh). Installs a release package from GitHub into ~/.orin.
#
#   curl -fsSL https://raw.githubusercontent.com/HenrySchwerdt/orin/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --uninstall
#
# Environment:
#   ORIN_VERSION       release to install, with or without the leading v (default: the newest release,
#                      pre-releases included; every Orin release is currently a pre-release)
#   ORIN_HOME          install root (default: ~/.orin)
#   ORIN_BIN_DIR       directory that gets an `orin` symlink (default: ~/.local/bin, only if it is on PATH)
#   ORIN_INSTALL_FROM  path to a local orin-<version>-<platform>.tar.gz instead of downloading
#                      (checksum is verified against <file>.sha256 or SHA256SUMS beside it when present)
#   ORIN_BASE_URL      release download base (default: https://github.com/HenrySchwerdt/orin/releases/download);
#                      file:// works, which is how the tests run
#   ORIN_PLATFORM      override platform detection (linux-x86_64, linux-aarch64, macos-arm64, macos-x86_64)
#   CC                 C compiler to look for (default: cc)
#
# Options: --uninstall, --print-platform, -h|--help
#
# The download is verified against the release's SHA256SUMS; a mismatch or a missing entry aborts
# the install before anything under ORIN_HOME is touched. The script never edits shell profiles.
set -eu

REPO=${ORIN_REPO:-HenrySchwerdt/orin}
BASE_URL=${ORIN_BASE_URL:-https://github.com/$REPO/releases/download}
API_URL=${ORIN_API_URL:-https://api.github.com/repos/$REPO/releases}
HOME_DIR=${ORIN_HOME:-${HOME:-}/.orin}
MARKER=.orin-install
case $HOME_DIR in /*) ;; *) printf 'orin-install: error: ORIN_HOME must be an absolute path (got %s)\n' "$HOME_DIR" >&2; exit 1 ;; esac

say() { printf '%s\n' "$*"; }
warn() { printf 'orin-install: warning: %s\n' "$*" >&2; }
die() { printf 'orin-install: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOT'
Orin installer. Usage: install.sh [--uninstall | --print-platform | --help]
Environment: ORIN_VERSION (default newest release), ORIN_HOME (default ~/.orin), ORIN_BIN_DIR (symlink dir,
default ~/.local/bin if on PATH), ORIN_INSTALL_FROM (local tarball), ORIN_BASE_URL, ORIN_PLATFORM, CC.
Details: docs/install.md
EOT
}

on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- platform

detect_platform() {
  if [ -n "${ORIN_PLATFORM:-}" ]; then printf '%s\n' "$ORIN_PLATFORM"; return; fi
  os=$(uname -s 2>/dev/null || echo unknown); m=$(uname -m 2>/dev/null || echo unknown)
  case $m in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=arm64 ;; *) arch=$m ;; esac
  case $os in
    Linux)
      [ "$arch" = arm64 ] && arch=aarch64
      printf 'linux-%s\n' "$arch" ;;
    Darwin)
      # An x86_64 shell under Rosetta on Apple silicon: install the native build.
      if [ "$arch" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then arch=arm64; fi
      printf 'macos-%s\n' "$arch" ;;
    MINGW*|MSYS*|CYGWIN*) die "Windows is not supported natively yet. Use WSL2 (see docs/windows.md): run this script inside the WSL shell." ;;
    *) die "unsupported OS '$os'. Orin releases exist for Linux and macOS (see docs/install.md for building from source)." ;;
  esac
}

check_platform() { # check_platform <tag>
  case $1 in
    linux-x86_64|linux-aarch64|macos-arm64|macos-x86_64) ;;
    *) die "no release package for platform '$1' (available: linux-x86_64, linux-aarch64, macos-arm64, macos-x86_64). Build from source: docs/bootstrap.md" ;;
  esac
}

# ---------------------------------------------------------------- tools

have() { command -v "$1" >/dev/null 2>&1; }

fetch() { # fetch <url> <output file>
  if have curl; then curl -fsSL --retry 3 -o "$2" "$1"
  elif have wget; then wget -q -O "$2" "$1"
  else die "need curl or wget to download Orin"; fi
}

sha256_of() { # sha256_of <file>
  if have sha256sum; then sha256sum "$1" | cut -d ' ' -f 1
  elif have shasum; then shasum -a 256 "$1" | cut -d ' ' -f 1
  elif have openssl; then openssl dgst -sha256 "$1" | sed 's/^.*= *//'
  else die "need sha256sum, shasum or openssl to verify the download (refusing to install unverified)"; fi
}

# ---------------------------------------------------------------- C compiler hints

cc_hint() {
  case $(uname -s 2>/dev/null) in
    Darwin) say "    xcode-select --install     (installs clang and the command line tools)" ;;
    *)
      id=$( (. /etc/os-release 2>/dev/null && echo "${ID:-} ${ID_LIKE:-}") || true)
      case " $id " in
        *" debian "*|*" ubuntu "*) say "    sudo apt-get update && sudo apt-get install -y build-essential" ;;
        *" fedora "*|*" rhel "*|*" centos "*) say "    sudo dnf install -y gcc make" ;;
        *" arch "*) say "    sudo pacman -S --needed base-devel" ;;
        *" alpine "*) say "    sudo apk add build-base gcompat     (gcompat: the release binaries are built against glibc)" ;;
        *" suse "*|*" opensuse "*) say "    sudo zypper install gcc make" ;;
        *) say "    install gcc or clang with your package manager, or set CC to one" ;;
      esac ;;
  esac
}

check_cc() {
  # shellcheck disable=SC2086  # CC may carry flags
  set -- ${CC:-cc}
  if have "$1"; then say "C compiler: $1 found"; return 0; fi
  warn "no C compiler ('$1') found. Orin compiles to C, so 'orin build/run/test' need one. Install one:"
  cc_hint >&2
  return 1
}

# ---------------------------------------------------------------- version lookup

latest_tag() {
  tmp_api=$1/releases.json
  # The newest release including pre-releases (the /releases/latest endpoint ignores them).
  if fetch "$API_URL?per_page=1" "$tmp_api" 2>/dev/null; then
    t=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp_api" | head -n 1)
    if [ -n "$t" ]; then printf '%s\n' "$t"; return 0; fi
  fi
  return 1
}

# ---------------------------------------------------------------- uninstall

uninstall() {
  [ -d "$HOME_DIR" ] || { say "nothing to uninstall: $HOME_DIR does not exist"; return 0; }
  [ -f "$HOME_DIR/$MARKER" ] || die "$HOME_DIR was not created by this installer (no $MARKER file); refusing to delete it"
  bindir=${ORIN_BIN_DIR:-${HOME:-}/.local/bin}
  if [ -h "$bindir/orin" ]; then
    case $(readlink "$bindir/orin") in
      "$HOME_DIR"/*) rm -f "$bindir/orin"; say "removed symlink $bindir/orin" ;;
      *) warn "$bindir/orin points elsewhere; left in place" ;;
    esac
  fi
  rm -rf "$HOME_DIR"
  say "removed $HOME_DIR"
  say "If you added $HOME_DIR/bin to PATH in a shell profile, remove that line."
}

# ---------------------------------------------------------------- install

install() {
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT INT TERM

  if [ -n "${ORIN_INSTALL_FROM:-}" ]; then
    [ -f "$ORIN_INSTALL_FROM" ] || die "ORIN_INSTALL_FROM: no such file: $ORIN_INSTALL_FROM"
    tarball=$ORIN_INSTALL_FROM
    fname=$(basename "$tarball")
    dir=$(dirname "$tarball")
    expected=
    if [ -f "$tarball.sha256" ]; then expected=$(cut -d ' ' -f 1 < "$tarball.sha256")
    elif [ -f "$dir/SHA256SUMS" ]; then expected=$(awk -v f="$fname" '$2 == f || $2 == "*" f { print $1 }' "$dir/SHA256SUMS")
    fi
    if [ -z "$expected" ]; then
      warn "no checksum file beside $tarball (<file>.sha256 or SHA256SUMS); installing a local file without verification"
    fi
    say "Installing from local file $tarball"
  else
    plat=$(detect_platform)
    check_platform "$plat"
    tag=${ORIN_VERSION:-}
    if [ -z "$tag" ]; then
      say "Looking up the newest release ..."
      tag=$(latest_tag "$work") || die "could not determine the newest release (GitHub API unreachable or rate limited). Set ORIN_VERSION, e.g. ORIN_VERSION=0.1.0-alpha.2"
    fi
    case $tag in v*) ;; *) tag=v$tag ;; esac
    ver=${tag#v}
    fname=orin-$ver-$plat.tar.gz
    say "Installing Orin $ver for $plat"
    tarball=$work/$fname
    fetch "$BASE_URL/$tag/$fname" "$tarball" || die "download failed: $BASE_URL/$tag/$fname (does release $tag exist for $plat?)"
    fetch "$BASE_URL/$tag/SHA256SUMS" "$work/SHA256SUMS" || die "download failed: $BASE_URL/$tag/SHA256SUMS (refusing to install without a checksum)"
    expected=$(awk -v f="$fname" '$2 == f || $2 == "*" f { print $1 }' "$work/SHA256SUMS")
    [ -n "$expected" ] || die "SHA256SUMS of $tag has no entry for $fname (refusing to install)"
  fi

  if [ -n "$expected" ]; then
    actual=$(sha256_of "$tarball")
    if [ "$actual" != "$expected" ]; then
      die "sha256 mismatch for $fname: expected $expected, got $actual. Nothing was installed."
    fi
    say "sha256 verified: $actual"
  fi

  # Unpack and sanity-check before touching ORIN_HOME.
  mkdir "$work/x"
  tar -xzf "$tarball" -C "$work/x" || die "could not unpack $fname"
  top=$(ls "$work/x")
  case $top in *'
'*|'') die "unexpected package layout in $fname" ;; esac
  pkg=$work/x/$top
  [ -x "$pkg/bin/orin" ] && [ -x "$pkg/libexec/orin" ] && [ -s "$pkg/VERSION" ] || die "$fname is not an Orin package (bin/orin, libexec/orin or VERSION missing)"
  ver=$(cat "$pkg/VERSION")

  if [ -d "$HOME_DIR" ] && [ ! -e "$HOME_DIR/$MARKER" ] && [ -n "$(ls -A "$HOME_DIR")" ]; then
    die "$HOME_DIR exists and is not an Orin install (set ORIN_HOME to another directory)"
  fi
  mkdir -p "$HOME_DIR/versions"
  : > "$HOME_DIR/$MARKER"
  rm -rf "$HOME_DIR/versions/$ver"
  mv "$pkg" "$HOME_DIR/versions/$ver"
  rm -f "$HOME_DIR/current"
  ln -s "versions/$ver" "$HOME_DIR/current"
  mkdir -p "$HOME_DIR/bin"
  rm -f "$HOME_DIR/bin/orin"
  ln -s "../current/bin/orin" "$HOME_DIR/bin/orin"
  # Drop older versions: pin ORIN_VERSION to go back.
  for d in "$HOME_DIR"/versions/*; do [ "$d" = "$HOME_DIR/versions/$ver" ] || rm -rf "$d"; done
  say "Installed Orin $ver to $HOME_DIR"

  # Put orin on PATH: symlink into a bin dir that is already on PATH, else print instructions.
  bindir=${ORIN_BIN_DIR:-${HOME:-}/.local/bin}
  linked=0
  if [ -n "${ORIN_BIN_DIR:-}" ] || on_path "$bindir"; then
    if mkdir -p "$bindir" 2>/dev/null && ln -sf "$HOME_DIR/bin/orin" "$bindir/orin" 2>/dev/null; then
      say "Linked $bindir/orin -> $HOME_DIR/bin/orin"; linked=1
    else
      warn "could not create a symlink in $bindir"
    fi
  fi
  if [ "$linked" = 0 ] || ! on_path "$bindir"; then
    say ""
    say "Add Orin to your PATH. For bash or zsh, put this line in ~/.profile, ~/.bashrc or ~/.zshrc:"
    say "    export PATH=\"$HOME_DIR/bin:\$PATH\""
    say "For fish:  fish_add_path $HOME_DIR/bin"
  fi

  say ""
  check_cc || true
  say ""
  say "Next: orin doctor      (checks the install)"
  say "      orin run $HOME_DIR/current/examples/hello.or"
}

# ---------------------------------------------------------------- main

case "${1:-}" in
  -h|--help) usage ;;
  --print-platform) detect_platform ;;
  --uninstall|uninstall) uninstall ;;
  "") install ;;
  *) die "unknown option '$1' (try --help)" ;;
esac
