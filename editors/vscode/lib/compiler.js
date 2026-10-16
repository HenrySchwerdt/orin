// Compiler discovery and version compatibility for the Orin VS Code extension.
// Pure Node (no `vscode` import) so it can be unit tested with `node --test`.
// All environment access (file system, env, exec) is injected through `deps`.

"use strict";

const path = require("path");

const INSTALL_DOCS_URL = "https://github.com/HenrySchwerdt/orin/blob/main/docs/install.md";

/**
 * Parse the output of `orin --version`. Releases print the bare package version
 * (`0.1.0-alpha.2`, possibly with a leading `v` or an `orin ` prefix); a source checkout
 * prints `development`.
 * @returns {{kind:"release",major:number,minor:number,patch:number,pre:string[],raw:string}
 *   | {kind:"development",raw:string} | {kind:"unknown",raw:string}}
 */
function parseVersion(text) {
  const raw = String(text == null ? "" : text).trim();
  const line = raw.split(/\r?\n/).find((l) => l.trim() !== "") || "";
  const word = line.trim().replace(/^orin\s+/i, "");
  if (/^development\b/i.test(word)) return { kind: "development", raw: "development" };
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?(?:\s.*)?$/.exec(word);
  if (!m) return { kind: "unknown", raw: word };
  return {
    kind: "release",
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
    pre: m[4] ? m[4].split(".") : [],
    raw: word.split(/\s/)[0].replace(/^v/, ""),
  };
}

/** Semver ordering (-1, 0, 1) of two parsed release versions, prerelease included. */
function compareVersions(a, b) {
  for (const k of ["major", "minor", "patch"]) {
    if (a[k] !== b[k]) return a[k] < b[k] ? -1 : 1;
  }
  if (a.pre.length === 0 && b.pre.length === 0) return 0;
  if (a.pre.length === 0) return 1;
  if (b.pre.length === 0) return -1;
  const n = Math.max(a.pre.length, b.pre.length);
  for (let i = 0; i < n; i++) {
    const x = a.pre[i];
    const y = b.pre[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const xn = /^\d+$/.test(x);
    const yn = /^\d+$/.test(y);
    if (xn && yn) {
      if (Number(x) !== Number(y)) return Number(x) < Number(y) ? -1 : 1;
    } else if (xn !== yn) {
      return xn ? -1 : 1;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

/**
 * Check a compiler version against the extension's declared compatibility
 * (`package.json` -> `orinCompiler`: `{ "min": "0.1.0-alpha.2", "series": "0.1" }`).
 * `development` builds (source checkouts) are always accepted; an unparsable version is
 * accepted with a warning, because older compilers may print something else.
 * @returns {{status:"ok"|"warn"|"incompatible", message:string}}
 */
function checkCompatibility(version, compat) {
  if (version.kind === "development") return { status: "ok", message: "development build from a source checkout" };
  if (version.kind === "unknown") {
    return {
      status: "warn",
      message: `could not understand the compiler version output "${version.raw}"; continuing, but this compiler may be too old`,
    };
  }
  const min = parseVersion(compat.min);
  const [sMajor, sMinor] = String(compat.series).split(".").map(Number);
  if (version.major !== sMajor || version.minor !== sMinor) {
    return {
      status: "incompatible",
      message: `Orin compiler ${version.raw} is outside the ${compat.series}.x series that this extension supports (needs ${compat.min} or newer in the ${compat.series}.x series)`,
    };
  }
  if (min.kind === "release" && compareVersions(version, min) < 0) {
    return {
      status: "incompatible",
      message: `Orin compiler ${version.raw} is older than the minimum supported ${compat.min}`,
    };
  }
  return { status: "ok", message: `Orin compiler ${version.raw}` };
}

function isExecutable(deps, p) {
  try {
    if (!deps.fs.statSync(p).isFile()) return false;
    deps.fs.accessSync(p, deps.fs.constants.X_OK);
    return true;
  } catch (_) {
    return false;
  }
}

function isDir(deps, p) {
  try {
    return deps.fs.statSync(p).isDirectory();
  } catch (_) {
    return false;
  }
}

/** The install.sh / docs/install.md locations, in the order a user is most likely to have them. */
function defaultInstallLocations(deps) {
  const home = deps.homedir || "";
  const out = [];
  const orinHome = deps.env.ORIN_HOME;
  if (orinHome && path.isAbsolute(orinHome)) out.push(path.join(orinHome, "bin", "orin"));
  if (home) {
    out.push(path.join(home, ".orin", "bin", "orin"));
    out.push(path.join(home, ".orin", "current", "bin", "orin"));
    out.push(path.join(home, ".local", "bin", "orin"));
  }
  out.push("/opt/homebrew/bin/orin", "/usr/local/bin/orin");
  return out;
}

/**
 * Candidates in discovery order. Each is `{ source, path, kind }` where kind is `"dev"` for
 * launchers inside an Orin source checkout (their version is not probed: `tools/orin` rebuilds
 * the compiler first) and `"release"` otherwise.
 *
 * Order: 1. setting, 2. workspace-local build / dev launcher, 3. PATH, 4. default install locations.
 */
function candidateList(deps, settingPath, workspaceFolders) {
  const list = [];
  if (settingPath && settingPath.trim() !== "" && settingPath.trim() !== "orin") {
    list.push({ source: "setting", path: settingPath.trim(), kind: "release" });
  }
  for (const folder of workspaceFolders || []) {
    // Only inside the orin repository itself: it has compiler/ and the tools/orin launcher.
    if (!isDir(deps, path.join(folder, "compiler")) || !isExecutable(deps, path.join(folder, "tools", "orin"))) continue;
    for (const rel of ["build/bootstrap/orin2", "build/dev/orin", "tools/orin"]) {
      list.push({ source: "workspace", path: path.join(folder, rel), kind: "dev" });
    }
  }
  const sep = deps.platform === "win32" ? ";" : ":";
  for (const dir of String(deps.env.PATH || "").split(sep)) {
    if (dir) list.push({ source: "PATH", path: path.join(dir, "orin"), kind: "release" });
  }
  for (const p of defaultInstallLocations(deps)) {
    list.push({ source: "install", path: p, kind: "release" });
  }
  return list;
}

/**
 * Find the first usable compiler and probe its version.
 * @param deps {{fs, env, homedir:string, platform:string, exec:(cmd:string,args:string[],opts:object)=>Promise<{code:number,stdout:string,stderr:string}>}}
 * @param opts {{serverPath?:string, workspaceFolders?:string[], compat:{min:string,series:string}}}
 * @returns {Promise<{found:boolean, path?:string, source?:string, kind?:string, version?:object,
 *   compat?:object, tried:string[], error?:string}>}
 */
async function discover(deps, opts) {
  const tried = [];
  const seen = new Set();
  for (const c of candidateList(deps, opts.serverPath, opts.workspaceFolders)) {
    if (seen.has(c.path)) continue;
    seen.add(c.path);
    tried.push(`${c.source}: ${c.path}`);
    if (!isExecutable(deps, c.path)) {
      // An explicitly configured path that does not work is an error, not a hint to keep looking:
      // silently using a different compiler would be surprising.
      if (c.source === "setting") {
        return { found: false, tried, error: `orin.serverPath is set to "${c.path}", which is not an executable file` };
      }
      continue;
    }
    let version = { kind: "development", raw: "development" };
    if (c.kind !== "dev") {
      const r = await deps.exec(c.path, ["--version"], { timeout: 10000 }).catch((e) => ({
        code: -1,
        stdout: "",
        stderr: String(e && e.message ? e.message : e),
      }));
      if (r.code !== 0) {
        if (c.source === "setting") {
          return {
            found: false,
            tried,
            error: `\`${c.path} --version\` failed${r.stderr ? `: ${r.stderr.trim()}` : ""}; is it the orin executable?`,
          };
        }
        continue;
      }
      version = parseVersion(r.stdout);
    }
    return {
      found: true,
      path: c.path,
      source: c.source,
      kind: c.kind,
      version,
      compat: checkCompatibility(version, opts.compat),
      tried,
    };
  }
  return { found: false, tried, error: "no `orin` executable found" };
}

module.exports = {
  INSTALL_DOCS_URL,
  parseVersion,
  compareVersions,
  checkCompatibility,
  candidateList,
  defaultInstallLocations,
  discover,
};
