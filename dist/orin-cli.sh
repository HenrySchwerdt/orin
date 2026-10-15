#!/usr/bin/env bash
# Release UX driver. Compiler semantics and TOML parsing stay in the self-hosted compiler.
# Bash 3.2 compatible (also the system Bash on macOS); no Python/Node runtime dependency.
set -eo pipefail
# Bash 3.2 treats an empty array as unset under nounset; every scalar is initialized explicitly.
HERE=${ORIN_PACKAGE_ROOT:?missing package root}
BIN=$HERE/libexec/orin
RT=$HERE/lib/orin/runtime
PF=$HERE/lib/orin/platform
CC=${CC:-cc}
color=auto quiet=false verbose=false ascii=false json=false
command=${1:---help}
[ $# -eq 0 ] || shift
args=()
# Program arguments after -- belong exclusively to the program.
while [ $# -gt 0 ]; do
  case $1 in
    --) args+=("$@"); break ;;
    --color=auto|--color=always|--color=never) color=${1#*=} ;;
    --color=*) printf 'error: expected --color=auto|always|never\n' >&2; exit 2 ;;
    --quiet) quiet=true ;;
    --verbose) verbose=true ;;
    --ascii) ascii=true ;;
    --format=json) json=true; args+=("$1") ;;
    *) args+=("$1") ;;
  esac
  shift
done
use_color=false
if [ "$color" = always ] || { [ "$color" = auto ] && [ -t 2 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-dumb}" != dumb ]; }; then use_color=true; fi
ui=(--diagnostic-style=rich "--color=$($use_color && echo always || echo never)")
$ascii && ui+=(--ascii)
$quiet && ui+=(--quiet)
$verbose && ui+=(--verbose)
mark_ok='✓'; mark_fail='✗'; mark_arrow='→'
if $ascii || [ "${TERM:-}" = dumb ]; then mark_ok=OK; mark_fail=FAIL; mark_arrow='>'; fi
safe() { LC_ALL=C sed 's/[[:cntrl:]]/?/g'; }
paint() { if $use_color; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
status() { $quiet || { paint 32 "$mark_ok"; printf ' %s\n' "$1" | safe; } >&2; }
fail() { paint '1;31' 'error:' >&2; printf ' %s\n' "$1" | safe >&2; exit "${2:-1}"; }
need_project() {
  project=$PWD
  while [ ! -f "$project/orin.toml" ]; do
    [ "$project" != / ] || fail $'No Orin project found.\n\n  Run `orin init` to create one, or pass a .or file.'
    project=${project%/*}; [ -n "$project" ] || project=/
  done
}
info() { "$BIN" __package info "$1" "$2"; }
valid_name() { case $1 in ''|-*|*[!a-zA-Z0-9_-]*) return 1 ;; esac; }
quote_toml() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
help_main() {
  cat <<'HELP'
Orin — build, test, and verify native programs

Usage: orin <command> [options]

Start a project
  init [name]          Create an application (--lib or --template http)
  add                  Add a path or Git dependency
  remove <name>        Remove a dependency

Develop
  run [path] -- [args]  Build and run
  dev [path]           Watch, rebuild, and restart
  build [path]         Build a native executable (--release)
  check [path]         Check types, ownership, and project policies
  test [path]          Run tests (--filter text, --watch)
  fmt [paths...]       Format sources (--check)

Manage
  deps [--tree]        Show dependencies
  fetch                Fetch locked dependencies (--locked, --offline)
  update [name]        Update Git resolutions
  clean                Remove generated build artifacts
  doctor               Check your installation

Inspect and integrate
  explain <code>       Explain a diagnostic
  api, effects, graph, diff, verify, compile, mir, lsp, mcp

Options: --color=auto|always|never  --ascii  --quiet  --verbose
Use `orin help <command>` for command help.

Get started: orin init hello && cd hello && orin run
HELP
}
help_command() {
  case $1 in
    init) echo 'Usage: orin init [name] [--lib | --template http]'; echo 'Create a project without overwriting existing files.' ;;
    add) echo 'Usage: orin add --path <directory> [--dev]'; echo '       orin add --git <url> [--tag <tag> | --rev <commit>] [--name <alias>] [--dev]' ;;
    build|run|dev) echo "Usage: orin $1 [file.or | project-directory] [--release] [--backend=c|llvm] [-o path] [-- program-arguments]" ;;
    test) echo 'Usage: orin test [path] [--filter text] [--watch] [--allow-empty] [--format=json]' ;;
    fmt) echo 'Usage: orin fmt [paths...] [--check | --stdout]' ;;
    check) echo 'Usage: orin check [path] [--format=json] [--deps] [--strict-contracts]' ;;
    fetch|deps|update|remove|clean) echo "Usage: orin $1 $([ "$1" = remove ] && echo '<name>' || true) [--locked] [--offline]" ;;
    *) echo "Usage: orin $1 — see the compiler command reference in docs/" ;;
  esac
}
init_project() {
  local target=. lib=false template=console arg name staging file
  while [ $# -gt 0 ]; do
    case $1 in
      --lib) lib=true ;;
      --template) [ $# -ge 2 ] || fail 'Missing template name.' 2; template=$2; shift ;;
      -*) fail "Unknown init option: $1" 2 ;;
      *) [ "$target" = . ] || fail 'init accepts one directory.' 2; target=$1 ;;
    esac; shift
  done
  case $template in console|http) ;; *) fail "Unknown template: $template" 2 ;; esac
  $lib && [ "$template" = http ] && fail '--lib cannot be combined with --template http.' 2
  name=$(basename "$(cd "$(dirname "$target")" && pwd)/$(basename "$target")")
  [ "$target" != . ] || name=$(basename "$PWD")
  valid_name "$name" || fail 'Use letters, numbers, underscores, and hyphens for a project name.' 2
  for file in orin.toml README.md tests/main_test.or; do [ ! -e "$target/$file" ] && [ ! -L "$target/$file" ] || fail "File already exists: $target/$file"; done
  local entry=src/main.or
  $lib && entry=src/module.or
  [ ! -e "$target/$entry" ] && [ ! -L "$target/$entry" ] || fail "File already exists: $target/$entry"
  for file in src tests; do [ ! -L "$target/$file" ] || fail "Refusing a symlink destination: $target/$file"; [ ! -e "$target/$file" ] || [ -d "$target/$file" ] || fail "Not a directory: $target/$file"; done
  staging=$(mktemp -d)
  mkdir -p "$staging/src" "$staging/tests"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nentry = "%s"\n' "$name" "$entry" > "$staging/orin.toml"
  if $lib; then
    printf 'export function greeting(): string {\n  return "Hello from Orin!";\n}\n' > "$staging/$entry"
    cat > "$staging/tests/main_test.or" <<'TEST'
import { greeting } from "../src";
import { assertEqString } from "std:test";

@Test
function greetingIsUseful(): void {
  assertEqString(greeting(), "Hello from Orin!", "greeting");
}
TEST
  else
    printf 'function main(): void {\n  console.log("Hello from Orin!");\n}\n' > "$staging/$entry"
    cat > "$staging/tests/main_test.or" <<'TEST'
import { assertEq } from "std:test";

@Test
function arithmeticWorks(): void {
  assertEq(2 + 2, 4, "addition");
}
TEST
  fi
  if [ "$template" = http ]; then
    cat > "$staging/$entry" <<'HTTP'
import { Host, useNet } from "std:host";
import { withListener, withAccept } from "std:net";

function main(host: Host): void {
  console.log("See the installed examples/http_server.or for the complete HTTP server.");
}
HTTP
    # Use the shipped, tested example instead of duplicating network API details here.
    [ -f "$HERE/examples/http_server.or" ] || { rm -rf "$staging"; fail 'The HTTP template is missing from this installation.'; }
    cp "$HERE/examples/http_server.or" "$staging/$entry"
  fi
  printf '# %s\n\nRun `orin run`, `orin test`, and `orin check`.\n\nBuild an optimized executable with `orin build --release`.\n' "$name" > "$staging/README.md"
  printf '/build/\n/.orin/\n' > "$staging/.gitignore"
  mkdir -p "$target/src" "$target/tests"
  cp "$staging/orin.toml" "$staging/README.md" "$target/"
  cp "$staging/$entry" "$target/$entry"
  cp "$staging/tests/main_test.or" "$target/tests/main_test.or"
  [ -e "$target/.gitignore" ] || cp "$staging/.gitignore" "$target/.gitignore"
  rm -rf "$staging"
  status "Created $name"
  if ! $quiet; then printf '\nNext steps\n' >&2; [ "$target" = . ] || printf '  cd %q\n' "$target" >&2; printf '  orin run\n  orin test\n' >&2; fi
}
# Call the compiler with presentation options; protocol servers bypass presentation entirely.
compiler() { "$BIN" "$@" "${ui[@]}"; }
project_target() {
  local path=${1:-}
  if [ -z "$path" ]; then need_project; target=$project
  elif [ -d "$path" ]; then project=$(cd "$path" && pwd); target=$project
  else target=$path; project=$(cd "$(dirname "$path")" && pwd); fi
}
# The cache hashes contents, not mtimes. Sources, manifests, toolchain, runtime and flags participate.
fingerprint() {
  local root=$1 file depname deppath depgit deptag deprev depdev
  {
    printf '%s\n' "$CC" "$profile" "$backend" "${target:-}"
    cksum "$BIN" "$HERE/bin/orin-cli.sh"
    for file in "$RT"/*.[ch] "$PF"/*.[ch]; do cksum "$file"; done
    while IFS= read -r -d '' file; do printf '%s\n' "$file"; cksum "$file"; done < <(find "$root" -type d \( -name .git -o -name build \) -prune -o -type f \( -name '*.or' -o -name orin.toml -o -name orin.lock \) -print0 | sort -z)
    if [ -f "$root/orin.toml" ]; then
      while IFS='|' read -r depname deppath depgit deptag deprev depdev; do
        [ -n "$deppath" ] || continue
        while IFS= read -r -d '' file; do printf '%s\n' "$file"; cksum "$file"; done < <(find "$root/$deppath" -type f \( -name '*.or' -o -name orin.toml \) -print0 | sort -z)
      done < <(info dependencies "$root")
    fi
    command -v "${CC%% *}" || true
    ${CC} --version 2>/dev/null || true
  } | cksum
}
native_build() {
  local src=$1 out=$2 tmp key previous='' ccflags=-O1
  [ "$profile" != release ] || ccflags=-O2
  tmp=$(mktemp -d)
  # Compile output goes to an adjacent temporary executable; failed builds preserve the last success.
  local generated=$tmp/out.c
  [ "$backend" != llvm ] || generated=$tmp/out.ll
  if ! compiler compile "$src" -o "$generated" "--backend=$backend"; then rm -rf "$tmp"; return 1; fi
  local ccbin=${CC%% *}
  if ! command -v "$ccbin" >/dev/null 2>&1; then rm -rf "$tmp"; fail "C compiler '$ccbin' was not found. Run 'orin doctor' for installation help."; fi
  mkdir -p "$(dirname "$out")"
  local emit=$out.tmp.$$
  local sources=("$RT/orin_runtime.c" "$PF/orin_platform.c")
  [ "$backend" != llvm ] || sources+=("$RT/orin_runtime_llvm.c")
  $verbose && printf 'Compiling with %s %s\n' "$CC" "$ccflags" >&2
  if ! ${CC} "$ccflags" -w -I "$RT" "$generated" "${sources[@]}" -lm -pthread -o "$emit" > "$tmp/cc.log" 2>&1; then
    local logfile=$out.build.log
    cp "$tmp/cc.log" "$logfile"
    printf 'error: Native build failed\n\n' >&2; head -15 "$logfile" >&2
    printf '\nFull compiler output: %s\n' "$logfile" >&2
    rm -f "$emit"; rm -rf "$tmp"; return 1
  fi
  mv -f "$emit" "$out"; rm -rf "$tmp"
}
build_command() {
  profile=dev backend=c
  local src='' output='' arg key cache
  program_args=()
  while [ $# -gt 0 ]; do
    case $1 in
      --) shift; program_args=("$@"); break ;;
      --release) profile=release ;;
      --backend=c|--backend=llvm) backend=${1#*=} ;;
      -o) [ $# -ge 2 ] || fail 'Missing output path.' 2; output=$2; shift ;;
      -*) fail "Unknown $command option: $1" 2 ;;
      *) [ -z "$src" ] || { if [ "$command" = run ]; then program_args+=("$1"); else fail 'Expected one source path.' 2; fi; }; [ -n "$src" ] || src=$1 ;;
    esac; shift
  done
  project_target "$src"
  local name
  if [ -f "$project/orin.toml" ]; then name=$(info name "$project"); else name=$(basename "$target" .or); fi
  valid_name "$name" || fail 'Invalid executable name in package manifest.'
  artifact=${output:-$project/build/$profile/$name}
  cache=$artifact.fingerprint
  key=$(fingerprint "$project")
  if [ -x "$artifact" ] && [ -f "$cache" ] && [ "$(cat "$cache")" = "$key" ]; then status "Up to date · $name"
  else
    $quiet || printf 'Building %s\n\n' "$name" >&2
    native_build "$target" "$artifact" || return 1
    printf '%s\n' "$key" > "$cache"
    status "Built $name"
    $quiet || printf '  %s\n' "$artifact" >&2
  fi
}
project_sources() {
  find "$project" -type d \( -name .git -o -name .orin -o -name build \) -prune -o -type f -name '*.or' ! -name '.orin-tests-*' -print0 | sort -z
}
format_command() {
  local files=() flags=() a
  for a in "$@"; do case $a in --check|--stdout) flags+=("$a");; -*) fail "Unknown fmt option: $a" 2;; *) files+=("$a");; esac; done
  if [ ${#files[@]} -eq 0 ]; then need_project; while IFS= read -r -d '' a; do files+=("$a"); done < <(project_sources); fi
  local expanded=() file
  for a in "${files[@]}"; do
    if [ -d "$a" ]; then while IFS= read -r -d '' file; do expanded+=("$file"); done < <(find "$a" -type d \( -name .git -o -name .orin -o -name build \) -prune -o -type f -name '*.or' -print0 | sort -z)
    else expanded+=("$a"); fi
  done
  [ ${#expanded[@]} -gt 0 ] || fail 'No Orin source files found.'
  compiler fmt "${flags[@]}" "${expanded[@]}"
}
test_command() {
  local src='' flags=() a allow=false entries=() file aggregate
  while [ $# -gt 0 ]; do
    case $1 in
      --allow-empty) allow=true ;;
      --format=json|--keep|--no-contracts) flags+=("$1") ;;
      --filter|--timeout|--out-dir|--runtime|--cc) [ $# -ge 2 ] || fail "Missing value for $1" 2; flags+=("$1" "$2"); shift ;;
      -*) fail "Unknown test option: $1" 2 ;;
      *) [ -z "$src" ] || fail 'Expected one test target.' 2; src=$1 ;;
    esac; shift
  done
  project_target "$src"
  if [ -f "$target" ]; then compiler test --runtime "$RT" --cc "$CC" "$target" "${flags[@]}"; return; fi
  local entry; entry=$(info entry "$project")
  aggregate=$(mktemp "$project/.orin-tests-XXXXXXXX.or")
  # An import-only entry discovers tests in the application and independent test files.
  printf 'import {} from "%s";\n' "$(quote_toml "./${entry%.or}")" > "$aggregate"
  if [ -d "$project/tests" ]; then
    while IFS= read -r -d '' file; do
      printf 'import {} from "%s";\n' "$(quote_toml "./${file#"$project/"}")" | sed 's/\.or";/";/' >> "$aggregate"
    done < <(find "$project/tests" -type f -name '*_test.or' -print0 | sort -z)
  fi
  local st=0
  compiler test --runtime "$RT" --cc "$CC" "$aggregate" "${flags[@]}" $($allow && printf '%s' '--allow-empty' || true) || st=$?
  rm -f "$aggregate"
  return "$st"
}
# Dependency management uses the compiler's manifest parser and immutable Git commits.
fetch_dependencies() {
  local root=$1 offline=${2:-false} locked=${3:-false} updating=${4:-} trail=${5:-}
  local name path giturl tag rev dev commit cached source lockline records='' existing='' spec
  case "|$trail|" in *"|$root|"*) fail "Package dependency cycle at $root" ;; esac
  local nexttrail=$trail\|$root
  local newlock; newlock=$(mktemp "$root/.orin-lock-XXXXXXXX")
  printf '# Orin lock v1: name|kind|source|selector|commit\n' > "$newlock"
  local depfile; depfile=$(mktemp)
  info dependencies "$root" > "$depfile" || { rm -f "$newlock" "$depfile"; return 1; }
  while IFS='|' read -r name path giturl tag rev dev; do
    [ -n "$name" ] || continue
    if [ -n "$path" ]; then
      source=$(cd "$root/$path" 2>/dev/null && pwd) || { rm -f "$newlock" "$depfile"; fail "Dependency '$name' does not exist: $path"; }
      [ -f "$source/src/module.or" ] || fail "Dependency '$name' has no src/module.or."
      printf '%s|path|%s||local\n' "$name" "$path" >> "$newlock"
      fetch_dependencies "$source" "$offline" "$locked" "$updating" "$nexttrail"
    else
      spec=${rev:-${tag:-HEAD}}
      commit=''
      if [ -f "$root/orin.lock" ] && [ "$updating" != '*' ] && [ "$updating" != "$name" ]; then
        commit=$(awk -F '|' -v n="$name" -v u="$giturl" -v s="$spec" '$1==n && $2=="git" && $3==u && $4==s {print $5}' "$root/orin.lock")
      fi
      [ -n "$commit" ] || ! $locked || fail "Lockfile needs an update for '$name'. Run 'orin fetch'."
      cached=$root/.orin/packages/$name
      if [ -z "$commit" ]; then
        $offline && fail "Cannot resolve '$name' offline without a matching lockfile."
        commit=$(git ls-remote -- "$giturl" "$spec" "refs/tags/$spec" "refs/tags/$spec^{}" "refs/heads/$spec" | tail -1 | cut -f1)
        if [ -z "$commit" ] && [[ "$spec" =~ ^[0-9a-fA-F]{40}$ ]]; then commit=$spec; fi
        [ -n "$commit" ] || fail "Cannot resolve '$name' at '$spec'."
      fi
      [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || fail "Invalid locked Git commit for '$name'."
      if [ ! -d "$cached/.git" ] || [ "$(git -C "$cached" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]; then
        $offline && fail "Dependency '$name' is not cached at its locked commit."
        local download; mkdir -p "$root/.orin/packages"; download=$(mktemp -d "$root/.orin/packages/.download-XXXXXXXX")
        git -C "$download" init -q
        git -C "$download" -c protocol.file.allow=always fetch -q --depth 1 -- "$giturl" "$commit" || { rm -rf "$download"; fail "Could not fetch '$name'."; }
        git -C "$download" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
        [ -f "$download/src/module.or" ] || { rm -rf "$download"; fail "Dependency '$name' has no src/module.or."; }
        rm -rf "$cached"; mv "$download" "$cached"
      fi
      printf '%s|git|%s|%s|%s\n' "$name" "$giturl" "$spec" "$commit" >> "$newlock"
      fetch_dependencies "$cached" "$offline" "$locked" '' "$nexttrail"
    fi
  done < "$depfile"
  rm -f "$depfile"
  if $locked; then
    if [ ! -f "$root/orin.lock" ] || ! cmp -s "$newlock" "$root/orin.lock"; then rm -f "$newlock"; fail 'Lockfile is out of date.'; fi
    rm -f "$newlock"
  else mv "$newlock" "$root/orin.lock"; fi
}
package_command() {
  need_project
  local name='' path='' giturl='' refkey='' ref='' dev=false offline=false locked=false tree=false arg
  while [ $# -gt 0 ]; do
    case $1 in
      --path|--git|--tag|--rev|--name) [ $# -ge 2 ] || fail "Missing value for $1" 2
        case $1 in --path) path=$2;; --git) giturl=$2;; --tag) refkey=tag; ref=$2;; --rev) refkey=rev; ref=$2;; --name) name=$2;; esac; shift ;;
      --dev) dev=true;; --offline) offline=true;; --locked) locked=true;; --tree) tree=true;;
      -*) fail "Unknown $command option: $1" 2;;
      *) [ -z "$name" ] || fail 'Expected one dependency name.' 2; name=$1;;
    esac; shift
  done
  if [ "$command" = deps ]; then
    local dn dp dg dt dr dd
    while IFS='|' read -r dn dp dg dt dr dd; do
      local suffix=''; [ "$dd" != true ] || suffix=' (dev)'
      printf '%s  %s%s\n' "$dn" "${dp:-$dg}" "$suffix"
      if $tree; then printf '  public API: src/module.or\n'; fi
    done < <(info dependencies "$project")
    return
  fi
  if [ "$command" = fetch ] || [ "$command" = update ]; then fetch_dependencies "$project" "$offline" "$locked" "$([ "$command" = update ] && echo "${name:-*}" || true)"; status 'Dependencies ready'; return; fi
  if [ "$command" = add ]; then
    [ -n "$path" ] || [ -n "$giturl" ] || fail 'Use --path or --git. Registry packages are not available yet.' 2
    [ -z "$path" ] || [ -z "$giturl" ] || fail 'Choose --path or --git.' 2
    if [ -n "$path" ]; then
      local depdir; depdir=$(cd "$path" && pwd)
      [ -n "$name" ] || name=$(info name "$depdir")
      # Store an absolute path if the user invokes add from a nested project directory.
      [ "$PWD" = "$project" ] || path=$depdir
    else
      [ -n "$name" ] || name=$(basename "${giturl%.git}")
    fi
    valid_name "$name" || fail 'Invalid dependency name.' 2
  else [ -n "$name" ] || fail 'Missing dependency name.' 2; fi
  local backup; backup=$(mktemp -d); cp "$project/orin.toml" "$backup/orin.toml"
  [ ! -f "$project/orin.lock" ] || cp "$project/orin.lock" "$backup/orin.lock"
  if [ "$command" = add ]; then
    "$BIN" __package edit add "$project" "$name" "$([ -n "$path" ] && echo path || echo git)" "${path:-$giturl}" "$refkey" "$ref" "$dev" || { rm -rf "$backup"; return 1; }
  else "$BIN" __package edit remove "$project" "$name" || { rm -rf "$backup"; return 1; }; fi
  # Resolution runs in a subshell so failures roll back both manifest and lockfile.
  if ! (fetch_dependencies "$project" "$offline" "$locked"); then
    cp "$backup/orin.toml" "$project/orin.toml"
    if [ -f "$backup/orin.lock" ]; then cp "$backup/orin.lock" "$project/orin.lock"; else rm -f "$project/orin.lock"; fi
    rm -rf "$backup"; return 1
  fi
  rm -rf "$backup"; status "Updated orin.toml and orin.lock · $name"
}
watch_command() {
  local mode=$1; shift
  local child='' last='' current='' st=0
  set -m
  stop_child() {
    if [ -n "$child" ]; then
      kill -TERM -- "-$child" 2>/dev/null || true
      local n=0
      while kill -0 -- "-$child" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
      kill -KILL -- "-$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true; child=''
    fi
  }
  trap 'stop_child; exit 130' INT TERM
  need_project
  profile=dev backend=c
  $quiet || printf 'Watching %s · Ctrl+C to stop\n\n' "$(info name "$project")" >&2
  while :; do
    current=$(fingerprint "$project")
    if [ "$current" != "$last" ]; then
      if [ "$mode" = test ]; then test_command "$@" || true
      elif build_command "$@"; then
        stop_child
        "$artifact" "${program_args[@]}" & child=$!
      else
        if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then printf 'Previous process is still running\n' >&2; fi
      fi
      last=$(fingerprint "$project")
    fi
    if [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null; then
      st=0; wait "$child" || st=$?; child=''
      printf 'Process exited · status %s\n' "$st" >&2
    fi
    sleep 0.3
  done
}
case $command in
  --help|-h|help)
    if [ ${#args[@]} -gt 0 ]; then help_command "${args[0]}"; else help_main; fi ;;
  --version|version) cat "$HERE/VERSION" ;;
  lsp|mcp) exec "$BIN" "$command" "${args[@]}" ;;
  *)
    for arg in "${args[@]}"; do if [ "$arg" = --help ] || [ "$arg" = -h ]; then help_command "$command"; exit 0; fi; done
    case $command in
      init) init_project "${args[@]}" ;;
      build) build_command "${args[@]}" ;;
      run) build_command "${args[@]}"; $quiet || printf '%s Running %s\n\n' "$mark_arrow" "$(basename "$artifact")" >&2; exec "$artifact" "${program_args[@]}" ;;
      dev) watch_command run "${args[@]}" ;;
      test)
        watching=false; testargs=(); for arg in "${args[@]}"; do if [ "$arg" = --watch ]; then watching=true; else testargs+=("$arg"); fi; done
        if $watching; then watch_command test "${testargs[@]}"; else test_command "${testargs[@]}"; fi ;;
      fmt) format_command "${args[@]}" ;;
      add|remove|fetch|update|deps) package_command "${args[@]}" ;;
      clean) need_project; [ ! -L "$project/build" ] || fail 'Refusing to clean a symlinked build directory.'; rm -rf "$project/build"; status 'Cleaned build artifacts' ;;
      doctor) ORIN_LEGACY_DRIVER=1 exec "$HERE/bin/orin" doctor ;;
      explain) [ ${#args[@]} -eq 1 ] || fail 'Usage: orin explain <diagnostic-code>' 2; case ${args[0]} in
        E0300) printf 'E0300: Unknown name or type\n\nCheck spelling, imports, and the declaration scope.\n' ;;
        E0400) printf 'E0400: Type mismatch\n\nThe value does not match the expected type. Orin does not implicitly coerce values.\n' ;;
        E0200) printf 'E0200: Syntax error\n\nUse the highlighted source location to check punctuation and expression syntax.\n' ;;
        E0301) printf 'E0301: Module not found\n\nCheck the import path and dependency declaration. Run `orin fetch` for Git dependencies.\n' ;;
        *) fail 'No extended explanation is available for this code yet.' 2;; esac ;;
      check|verify|api|effects|graph|mir)
        # Commands with no explicit path target the nearest project.
        haspath=false; expect=false
        for arg in "${args[@]}"; do
          if $expect; then expect=false; continue; fi
          case $arg in --z3|--module|--function|--check|-o) expect=true;; -*) ;; *) haspath=true;; esac
        done
        if ! $haspath; then need_project; args=("$project" "${args[@]}"); fi
        compiler "$command" "${args[@]}" ;;
      compile|diff) compiler "$command" "${args[@]}" ;;
      *) fail "Unknown command '$command'. Run 'orin --help' to see available commands." 2 ;;
    esac ;;
esac
