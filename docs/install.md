# Installing Orin

Orin ships as a tarball per platform. Every release (all are experimental pre-releases today) has:

| Platform | File |
|---|---|
| Linux x86-64 | `orin-<version>-linux-x86_64.tar.gz` |
| Linux arm64 | `orin-<version>-linux-aarch64.tar.gz` |
| macOS Apple silicon | `orin-<version>-macos-arm64.tar.gz` |
| macOS Intel | `orin-<version>-macos-x86_64.tar.gz` |

plus `<file>.sha256` for each and one combined `SHA256SUMS`. Windows: [windows.md](windows.md) (WSL2 today,
native later).

**Requirement:** a C compiler (`cc`, gcc or clang) on PATH, because the default backend emits C and
`orin build/run/test` compile it. The release binaries are built on glibc (Linux) and the macOS runners'
system libraries; on Alpine/musl see "Troubleshooting".

## One-line install (Linux, macOS)

```sh
curl -fsSL https://raw.githubusercontent.com/HenrySchwerdt/orin/main/install.sh | sh
```

(Read the script first if you like: it is [`install.sh`](../install.sh), about 250 lines of POSIX sh.)

What it does:
1. Detects OS and architecture (an x86_64 shell under Rosetta installs the arm64 build).
2. Finds the newest release (pre-releases included) or uses `ORIN_VERSION`.
3. Downloads the tarball and `SHA256SUMS`, and **verifies the sha256**. A mismatch, a missing checksum file or
   a missing entry aborts before anything is installed (fails closed). If no `sha256sum`, `shasum` or
   `openssl` exists it refuses to continue.
4. Installs to `~/.orin` (`versions/<version>/`, `current` symlink, `bin/orin`). Only one version is kept.
5. Symlinks `~/.local/bin/orin` when that directory is already on PATH; otherwise prints the `export PATH=...`
   line to add. It never edits your shell profile.
6. Checks for a C compiler and prints a hint for your system if there is none (apt, dnf, pacman, apk, zypper,
   `xcode-select --install` on macOS).

Then:
```sh
orin doctor
orin run ~/.orin/current/examples/hello.or
```

### Options

| Variable / option | Meaning |
|---|---|
| `ORIN_VERSION=0.1.0-alpha.2` | install this release (a leading `v` is accepted). Default: newest |
| `ORIN_HOME=/opt/orin` | install root, absolute path (default `~/.orin`) |
| `ORIN_BIN_DIR=/usr/local/bin` | directory for the `orin` symlink (default `~/.local/bin`, only linked if on PATH; when you set it explicitly it is always linked) |
| `ORIN_INSTALL_FROM=./orin-....tar.gz` | install a local tarball (no network). The checksum is verified against `<file>.sha256` or a `SHA256SUMS` beside it when one exists, otherwise a warning is printed |
| `ORIN_BASE_URL`, `ORIN_API_URL`, `ORIN_REPO` | where releases come from (mirrors, tests; `file://` works) |
| `ORIN_PLATFORM=linux-aarch64` | override detection |
| `CC` | compiler the check looks for |
| `--uninstall` | remove the install and its symlink |

Examples:
```sh
curl -fsSL .../install.sh | ORIN_VERSION=0.1.0-alpha.2 sh      # pin
curl -fsSL .../install.sh | sh -s -- --uninstall              # uninstall
```

The installer only deletes a directory that it created itself (it writes a `.orin-install` marker), so a wrong
`ORIN_HOME` cannot remove an unrelated directory.

The latest release is found with the GitHub API (`/releases?per_page=1`), which is rate limited to 60
requests per hour per IP for anonymous callers; pin `ORIN_VERSION` in CI.

## Manual tarball

```sh
tar xzf orin-<version>-<platform>.tar.gz
cd orin-<version>-<platform>
bin/orin doctor
bin/orin run examples/hello.or
```

Verify before you unpack (`SHA256SUMS` is a release asset):
```sh
sha256sum -c --ignore-missing SHA256SUMS            # Linux
shasum -a 256 -c SHA256SUMS 2>/dev/null | grep "$(ls orin-*.tar.gz)"   # macOS
```
`bin/orin` works from wherever you unpack it and through symlinks, so
`ln -s "$PWD/bin/orin" ~/.local/bin/orin` is enough to put it on PATH.

## `orin doctor`

```
$ orin doctor
orin doctor
  [ ok ] version: 0.1.0-alpha.2
  [ ok ] install layout: /home/me/.orin/versions/0.1.0-alpha.2
  [ ok ] C compiler: cc (cc (Ubuntu 13.2.0-23ubuntu4) 13.2.0)
  [ ok ] end to end: compiled and ran a test program
  [ ok ] PATH: /home/me/.local/bin/orin
All good.
```
It checks the version file, that the compiler, runtime and platform files are present, that `$CC` (default `cc`)
can compile and link a program, that a small Orin program builds and runs, and that `orin` on PATH is this
install. Each problem prints a `fix:` line; failures give exit status 1, warnings (for example PATH) do not.
`orin --version` prints the package version.

## Updating and uninstalling

Update by running the installer again (it replaces the previous version). Uninstall with `--uninstall`
(above) or, for a manual install, delete the directory and the symlink.

## Building from source

See [bootstrap.md](bootstrap.md): `./tools/bootstrap.sh` builds the compiler from the committed seed with a
C compiler, `python3`, `gzip` and `sha256sum`/`shasum`; `./tools/package.sh <version> <platform>` then makes
the same tarball a release contains.

## Troubleshooting

- **`orin: command not found`**: add `~/.orin/bin` to PATH (the installer printed the line); `orin doctor`
  prints it again.
- **`no C compiler`**: install one, see the hint printed by `install.sh` / `orin doctor`
  (Debian/Ubuntu: `build-essential`; Fedora: `gcc`; Arch: `base-devel`; Alpine: `build-base`; macOS:
  `xcode-select --install`). Use another compiler with `CC=clang orin run ...`.
- **sha256 mismatch**: the download was corrupted or tampered with. Nothing was installed; retry, and if it
  persists, open an issue.
- **Alpine / musl**: the release binary is linked against glibc. Install `gcompat` (`apk add gcompat`) or build
  from source (above).
- **macOS "cannot be opened because the developer cannot be verified"**: files fetched by `curl` or the
  installer are not quarantined; a tarball downloaded in a browser is. Run `xattr -dr com.apple.quarantine
  <dir>` on the unpacked directory. (Releases are not notarised yet.)
- **Behind a proxy**: `curl` honours `https_proxy`; or download the tarball and use `ORIN_INSTALL_FROM`.
