"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fsReal = require("node:fs");
const {
  parseVersion,
  compareVersions,
  checkCompatibility,
  candidateList,
  discover,
} = require("../lib/compiler.js");

const COMPAT = { min: "0.1.0-alpha.2", series: "0.1" };

/** A fake file system: `files` are executable files, `dirs` are directories. */
function fakeDeps({ files = [], dirs = [], env = {}, versions = {}, homedir = "/home/u", nonExec = [] } = {}) {
  const fileSet = new Set(files.concat(nonExec));
  const dirSet = new Set(dirs);
  const calls = [];
  return {
    calls,
    homedir,
    platform: "linux",
    env: { PATH: "/usr/bin:/home/u/.local/bin", ...env },
    fs: {
      constants: fsReal.constants,
      statSync(p) {
        if (fileSet.has(p)) return { isFile: () => true, isDirectory: () => false };
        if (dirSet.has(p)) return { isFile: () => false, isDirectory: () => true };
        throw new Error("ENOENT " + p);
      },
      accessSync(p) {
        if (!files.includes(p)) throw new Error("EACCES " + p);
      },
    },
    async exec(cmd, args) {
      calls.push([cmd, ...args]);
      const v = versions[cmd];
      if (v === undefined) return { code: 1, stdout: "", stderr: "boom" };
      return { code: 0, stdout: v, stderr: "" };
    },
  };
}

test("parseVersion: release, prefixes, prerelease, build metadata", () => {
  const v = parseVersion("0.1.0-alpha.2\n");
  assert.deepStrictEqual([v.kind, v.major, v.minor, v.patch, v.pre, v.raw], ["release", 0, 1, 0, ["alpha", "2"], "0.1.0-alpha.2"]);
  assert.strictEqual(parseVersion("v1.2.3").raw, "1.2.3");
  assert.strictEqual(parseVersion("orin 0.1.4").patch, 4);
  assert.strictEqual(parseVersion("0.1.0+abc").pre.length, 0);
  assert.strictEqual(parseVersion("\n\n0.2.0\nextra").minor, 2);
});

test("parseVersion: development and unknown", () => {
  assert.strictEqual(parseVersion("development\n").kind, "development");
  assert.strictEqual(parseVersion("").kind, "unknown");
  assert.strictEqual(parseVersion("usage: orin ...").kind, "unknown");
  assert.strictEqual(parseVersion(undefined).kind, "unknown");
});

test("compareVersions follows semver precedence", () => {
  const p = parseVersion;
  assert.strictEqual(compareVersions(p("0.1.0-alpha.2"), p("0.1.0-alpha.10")), -1);
  assert.strictEqual(compareVersions(p("0.1.0-alpha.2"), p("0.1.0")), -1);
  assert.strictEqual(compareVersions(p("0.1.0"), p("0.1.0-rc.1")), 1);
  assert.strictEqual(compareVersions(p("0.1.1"), p("0.1.0")), 1);
  assert.strictEqual(compareVersions(p("0.1.0-alpha"), p("0.1.0-alpha.1")), -1);
  assert.strictEqual(compareVersions(p("0.1.0-1"), p("0.1.0-alpha")), -1);
  assert.strictEqual(compareVersions(p("0.1.0"), p("0.1.0")), 0);
});

test("checkCompatibility", () => {
  const c = (s) => checkCompatibility(parseVersion(s), COMPAT).status;
  assert.strictEqual(c("0.1.0-alpha.2"), "ok");
  assert.strictEqual(c("0.1.3"), "ok");
  assert.strictEqual(c("development"), "ok");
  assert.strictEqual(c("0.1.0-alpha.1"), "incompatible");
  assert.strictEqual(c("0.2.0"), "incompatible");
  assert.strictEqual(c("1.1.0"), "incompatible");
  assert.strictEqual(c("garbage"), "warn");
  assert.match(checkCompatibility(parseVersion("0.2.0"), COMPAT).message, /0\.1\.x series/);
});

test("candidate order: setting, workspace, PATH, install locations", () => {
  const ws = "/w/orin";
  const deps = fakeDeps({ dirs: [ws + "/compiler"], files: [ws + "/tools/orin"], env: { ORIN_HOME: "/opt/orin" } });
  const list = candidateList(deps, "/custom/orin", [ws]);
  assert.deepStrictEqual(
    list.map((c) => c.source + ":" + c.path),
    [
      "setting:/custom/orin",
      `workspace:${ws}/build/bootstrap/orin2`,
      `workspace:${ws}/build/dev/orin`,
      `workspace:${ws}/tools/orin`,
      "PATH:/usr/bin/orin",
      "PATH:/home/u/.local/bin/orin",
      "install:/opt/orin/bin/orin",
      "install:/home/u/.orin/bin/orin",
      "install:/home/u/.orin/current/bin/orin",
      "install:/home/u/.local/bin/orin",
      "install:/opt/homebrew/bin/orin",
      "install:/usr/local/bin/orin",
    ]
  );
});

test("candidate list: default setting `orin` is ignored; non-orin workspaces add nothing", () => {
  const deps = fakeDeps({ dirs: ["/w/app"] });
  const list = candidateList(deps, "orin", ["/w/app"]);
  assert.ok(list.every((c) => c.source === "PATH" || c.source === "install"));
});

test("discover: setting wins over everything", async () => {
  const deps = fakeDeps({
    files: ["/custom/orin", "/usr/bin/orin"],
    versions: { "/custom/orin": "0.1.0-alpha.2\n", "/usr/bin/orin": "0.1.1\n" },
  });
  const r = await discover(deps, { serverPath: "/custom/orin", compat: COMPAT });
  assert.strictEqual(r.source, "setting");
  assert.strictEqual(r.path, "/custom/orin");
  assert.strictEqual(r.compat.status, "ok");
});

test("discover: bad setting is an error and does not fall through", async () => {
  const deps = fakeDeps({ files: ["/usr/bin/orin"], versions: { "/usr/bin/orin": "0.1.1" } });
  const r = await discover(deps, { serverPath: "/nope/orin", compat: COMPAT });
  assert.strictEqual(r.found, false);
  assert.match(r.error, /orin\.serverPath/);
  assert.strictEqual(deps.calls.length, 0);
});

test("discover: setting that fails --version is an error", async () => {
  const deps = fakeDeps({ files: ["/custom/orin"] });
  const r = await discover(deps, { serverPath: "/custom/orin", compat: COMPAT });
  assert.strictEqual(r.found, false);
  assert.match(r.error, /--version/);
});

test("discover: workspace dev launcher beats PATH and is not probed", async () => {
  const ws = "/w/orin";
  const deps = fakeDeps({
    dirs: [ws + "/compiler"],
    files: [ws + "/tools/orin", "/usr/bin/orin"],
    versions: { "/usr/bin/orin": "0.1.0" },
  });
  const r = await discover(deps, { workspaceFolders: [ws], compat: COMPAT });
  assert.strictEqual(r.source, "workspace");
  assert.strictEqual(r.path, ws + "/tools/orin");
  assert.strictEqual(r.version.kind, "development");
  assert.strictEqual(deps.calls.length, 0);
});

test("discover: build/bootstrap/orin2 preferred over tools/orin", async () => {
  const ws = "/w/orin";
  const deps = fakeDeps({ dirs: [ws + "/compiler"], files: [ws + "/tools/orin", ws + "/build/bootstrap/orin2"] });
  const r = await discover(deps, { workspaceFolders: [ws], compat: COMPAT });
  assert.strictEqual(r.path, ws + "/build/bootstrap/orin2");
});

test("discover: PATH before default install locations; skips non-executable and broken entries", async () => {
  const deps = fakeDeps({
    files: ["/home/u/.local/bin/orin", "/home/u/.orin/bin/orin"],
    nonExec: ["/usr/bin/orin"],
    versions: { "/home/u/.local/bin/orin": "0.1.0-alpha.2", "/home/u/.orin/bin/orin": "0.1.0-alpha.3" },
  });
  const r = await discover(deps, { compat: COMPAT });
  assert.strictEqual(r.source, "PATH");
  assert.strictEqual(r.path, "/home/u/.local/bin/orin");
});

test("discover: falls back to default install location when not on PATH", async () => {
  const deps = fakeDeps({ files: ["/home/u/.orin/bin/orin"], versions: { "/home/u/.orin/bin/orin": "0.1.0-alpha.2" } });
  const r = await discover(deps, { compat: COMPAT });
  assert.strictEqual(r.found, true);
  assert.strictEqual(r.source, "install");
  assert.deepStrictEqual(deps.calls, [["/home/u/.orin/bin/orin", "--version"]]);
});

test("discover: honours ORIN_HOME", async () => {
  const deps = fakeDeps({ env: { ORIN_HOME: "/opt/orin" }, files: ["/opt/orin/bin/orin"], versions: { "/opt/orin/bin/orin": "0.1.2" } });
  const r = await discover(deps, { compat: COMPAT });
  assert.strictEqual(r.path, "/opt/orin/bin/orin");
});

test("discover: reports incompatible version but still returns the compiler", async () => {
  const deps = fakeDeps({ files: ["/usr/bin/orin"], versions: { "/usr/bin/orin": "0.3.0" } });
  const r = await discover(deps, { compat: COMPAT });
  assert.strictEqual(r.found, true);
  assert.strictEqual(r.compat.status, "incompatible");
});

test("discover: nothing found lists everything tried", async () => {
  const deps = fakeDeps();
  const r = await discover(deps, { compat: COMPAT });
  assert.strictEqual(r.found, false);
  assert.match(r.error, /no `orin`/);
  assert.ok(r.tried.includes("install: /home/u/.orin/bin/orin"));
  assert.ok(r.tried.includes("PATH: /usr/bin/orin"));
});
