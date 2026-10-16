#!/usr/bin/env python3
"""Release CLI journeys, isolated from the user's installation and network."""
import json
import os
from pathlib import Path
import shutil
import signal
import time
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = tempfile.TemporaryDirectory(prefix="orin-cli-")
        cls.base = Path(cls.sandbox.name)
        package = cls.base / "install"
        (package / "bin").mkdir(parents=True)
        (package / "libexec").mkdir()
        shutil.copy2(ROOT / "dist/orin", package / "bin/orin")
        if (ROOT / "dist/orin-cli.sh").exists():
            shutil.copy2(ROOT / "dist/orin-cli.sh", package / "bin/orin-cli.sh")
        compiler = Path(os.environ.get("ORIN2", ROOT / "build/dev/orin")).resolve()
        (package / "libexec/orin").symlink_to(compiler)
        (package / "lib/orin").mkdir(parents=True)
        (package / "lib/orin/runtime").symlink_to(ROOT / "runtime")
        (package / "lib/orin/platform").symlink_to(ROOT / "platform")
        (package / "examples").symlink_to(ROOT / "examples")
        (package / "VERSION").write_text("test\n")
        cls.cli = package / "bin/orin"
        cls.compiler = compiler

    @classmethod
    def tearDownClass(cls):
        cls.sandbox.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=self.base)
        self.cwd = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args, code=0, cwd=None, env=None):
        result = subprocess.run([str(self.cli), *args], cwd=cwd or self.cwd,
                                env={**os.environ, "NO_COLOR": "1", **(env or {})},
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def run_compiler(self, *args, code=0, cwd=None):
        result = subprocess.run([str(self.compiler), *args], cwd=cwd or self.cwd,
                                env={**os.environ, "NO_COLOR": "1"},
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def workspace(self):
        root = self.cwd / "workspace with spaces"
        shutil.copytree(ROOT / "tests/workspace/ok/topo_order", root)
        return root

    def test_workspace_discovery_and_standalone_compatibility(self):
        root = self.workspace()
        nested = root / "app/nested/src"
        nested.mkdir(parents=True)
        expected = "lib  lib\napp  app\n"
        for cwd in (root, root / "app", nested):
            self.assertEqual(self.run_cli("workspace", "list", cwd=cwd).stdout, expected)
            self.assertEqual(self.run_compiler("workspace", "list", cwd=cwd).stdout, expected)
        self.assertEqual(self.run_compiler("workspace", "list", "--root", str(root)).stdout, expected)
        self.assertEqual(self.run_cli("workspace", "list", "--root", str(root)).stdout, expected)
        self.run_cli("check", cwd=root / "lib")
        self.run_cli("workspace", "list", code=1)
        self.run_compiler("workspace", "list", code=1)

    def test_workspace_lock_check_and_stale_lock(self):
        root = self.workspace()
        self.run_cli("workspace", "check", cwd=root, code=1)
        self.run_cli("workspace", "lock", cwd=root / "app")
        before = (root / "orin.lock").read_bytes()
        self.run_cli("workspace", "check", cwd=root / "lib")
        self.assertEqual(before, (root / "orin.lock").read_bytes())
        manifest = root / "lib/orin.toml"
        manifest.write_text(manifest.read_text().replace('0.1.0', '0.1.1'))
        self.assertIn("E0509", self.run_cli("workspace", "check", cwd=root, code=1).stderr)
        self.assertEqual(before, (root / "orin.lock").read_bytes())
        self.run_compiler("workspace", "lock", "--root", str(root))
        self.run_compiler("workspace", "check", "--root", str(root))
        (root / "orin.lock").write_text('[member.removed]\npath = "old"\nversion = "0.0.1"\ndependencies = []\n')
        self.run_cli("workspace", "lock", cwd=root)
        self.run_cli("workspace", "check", cwd=root)
        self.assertNotIn("removed", (root / "orin.lock").read_text())

    def test_workspace_refuses_project_or_unknown_lock(self):
        root = self.workspace()
        for contents in ("# Orin lock v1: name|kind|source|selector|commit\nx|git|repo|HEAD|abc\n",
                         "do not overwrite this lock\n",
                         '[member.notes]\nunknown = "data"\n',
                         '[member.app]\npath = "app"\nversion = "0.1.0"\n',
                         '[member.app]\npath = true\nversion = "0.1.0"\ndependencies = []\n',
                         '[member.app]\npath = "app"\nversion = 1\ndependencies = []\n',
                         '[member.app]\npath = "app"\nversion = "0.1.0"\ndependencies = "lib"\n',
                         '[member.app]\npath = "app"\nversion = "0.1.0"\ndependencies = [1]\n',
                         '[member.app]\npath = "app"\nversion = "0.1.0"\ndependencies = []\nunknown = "data"\n',
                         '[member.app]\npath = "app"\npath = "other"\nversion = "0.1.0"\ndependencies = []\n'):
            (root / "orin.lock").write_text(contents)
            for invoke in (self.run_cli, self.run_compiler):
                invoke("workspace", "lock", cwd=root, code=1)
                self.assertEqual((root / "orin.lock").read_bytes(), contents.encode())
        (root / "orin.lock").unlink()
        (root / "orin.lock").mkdir()
        self.run_cli("workspace", "lock", cwd=root, code=1)
        self.assertTrue((root / "orin.lock").is_dir())

    def test_workspace_read_write_errors_and_terminal_options(self):
        root = self.workspace()
        manifest = root / "lib/orin.toml"
        original = manifest.read_bytes()
        manifest.unlink()
        manifest.mkdir()
        self.assertIn("cannot read", self.run_cli("workspace", "list", cwd=root, code=1).stderr)
        manifest.rmdir()
        manifest.write_text("")
        empty = self.run_cli("workspace", "list", cwd=root, code=1)
        self.assertIn("error[", empty.stderr)
        self.assertNotIn("E0505", empty.stderr)
        manifest.write_bytes(original)
        workspace = root / "orin-workspace.toml"
        workspace.write_text('[workspace]\nmembers = ["../outside"]\n')
        plain = self.run_cli("workspace", "list", cwd=root, code=1)
        self.assertNotIn("\x1b", plain.stderr)
        self.assertIn("^", plain.stderr)
        colored = self.run_cli("workspace", "list", "--color=always", cwd=root, code=1)
        self.assertIn("\x1b[", colored.stderr)
        workspace.unlink()
        workspace.mkdir()
        self.run_compiler("workspace", "list", "--root", str(root), code=1)
        workspace.rmdir()
        workspace.write_text('[workspace]\nmembers = ["app", "lib"]\n')
        if os.geteuid() != 0:
            root.chmod(0o555)
            try:
                self.assertIn("cannot write", self.run_cli("workspace", "lock", cwd=root, code=1).stderr)
                self.assertFalse((root / "orin.lock").exists())
            finally:
                root.chmod(0o755)

    @unittest.skipIf(os.geteuid() == 0, "permission failure requires an ordinary user")
    def test_workspace_enumeration_failure_preserves_lock(self):
        root = self.cwd / "workspace"
        shutil.copytree(ROOT / "tests/workspace/ok/single", root)
        library = root / "library"
        shutil.copytree(root / "app", library / "base")
        manifest = library / "base/orin.toml"
        manifest.write_text(manifest.read_text().replace('name = "app"', 'name = "base"'))
        (root / "orin-workspace.toml").write_text('[workspace]\nmembers = ["app", "library/*"]\n')
        self.run_cli("workspace", "lock", cwd=root)
        before = (root / "orin.lock").read_bytes()
        library.chmod(0)
        try:
            for sub in ("list", "lock"):
                result = subprocess.run([str(self.cli), "workspace", sub], cwd=root,
                                        capture_output=True, text=True, timeout=120)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(before, (root / "orin.lock").read_bytes())
        finally:
            library.chmod(0o755)

    def test_workspace_strict_usage_and_json(self):
        root = self.workspace()
        for invoke in (self.run_cli, self.run_compiler):
            for args in ((), ("wat",), ("list", "extra"), ("list", "--unknown"),
                         ("list", "--root"), ("list", "--root", "--unknown"),
                         ("list", "--root", str(root), "--root", str(root)),
                         ("list", "--format=json")):
                invoke("workspace", *args, cwd=root, code=2)
        self.assertIn("workspace", self.run_cli("--help").stdout)
        self.assertIn("list|lock|check", self.run_cli("help", "workspace").stdout)

    def test_workspace_list_escapes_terminal_controls(self):
        root = self.cwd / "workspace"
        shutil.copytree(ROOT / "tests/workspace/ok/single", root)
        manifest = root / "app/orin.toml"
        manifest.write_text(manifest.read_text().replace('name = "app"', 'name = "app\\nspoof"'))
        for invoke in (self.run_cli, self.run_compiler):
            result = invoke("workspace", "list", cwd=root)
            self.assertEqual(result.stdout, "app\\x0aspoof  app\n")

    def test_workspace_compact_diagnostic_escapes_terminal_controls(self):
        root = self.cwd / "workspace\x1b[31m"
        shutil.copytree(ROOT / "tests/workspace/ok/single", root)
        (root / "orin-workspace.toml").write_text('[workspace]\nmembers = ["../\x1b[31m"]\n')
        result = self.run_compiler("workspace", "list", cwd=root, code=1)
        self.assertNotIn("\x1b", result.stderr)
        self.assertIn("\\x1b", result.stderr)
        self.assertIn("E0505", result.stderr)
        result = self.run_compiler("workspace", "list", "--root", str(root), code=1)
        self.assertNotIn("\x1b", result.stderr)
        self.assertIn("workspace\\x1b", result.stderr)

    def test_workspace_fixtures_through_cli(self):
        count = 0
        for group in ("ok", "fail"):
            fixtures = sorted((ROOT / "tests/workspace" / group).iterdir())
            self.assertTrue(fixtures)
            for fixture in fixtures:
                if not fixture.is_dir():
                    continue
                with self.subTest(fixture=fixture.name):
                    expected = (fixture / "expected.txt").read_text().strip()
                    command = "check" if fixture.name == "stale_lockfile" else "list"
                    result = self.run_cli("workspace", command, cwd=fixture,
                                          code=0 if group == "ok" else 1)
                    if group == "ok":
                        self.assertEqual([line.split("  ", 1)[0] for line in result.stdout.splitlines()],
                                         expected.splitlines())
                    else:
                        diagnostic, line = expected.split()
                        self.assertIn("error[" + diagnostic + "]", result.stderr)
                        self.assertRegex(result.stderr, r":" + line + r":\d+")
                    count += 1
        self.assertEqual(count, 30)


    def test_help_and_usage(self):
        self.assertIn("init", self.run_cli("--help").stdout)
        self.assertIn("--lib", self.run_cli("help", "init").stdout)
        self.run_cli("wat", code=2)
        self.run_cli("build", "--unknown", code=2)

    def test_application_journey_and_cache(self):
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.assertTrue((project / "tests/main_test.or").is_file())
        self.assertIn("Hello", self.run_cli("run", cwd=project).stdout)
        self.assertIn("passed", self.run_cli("test", cwd=project).stdout)
        self.run_cli("check", cwd=project / "src")
        self.run_cli("build", cwd=project)
        binary = project / "build/dev/hello"
        self.assertTrue(binary.is_file())
        before = binary.stat().st_mtime_ns
        self.run_cli("build", cwd=project)
        self.assertEqual(before, binary.stat().st_mtime_ns)
        self.run_cli("fmt", "--check", cwd=project)

    def test_init_conflict_is_unchanged(self):
        (self.cwd / "src").mkdir()
        (self.cwd / "src/main.or").write_text("keep me")
        self.run_cli("init", code=1)
        self.assertEqual((self.cwd / "src/main.or").read_text(), "keep me")
        self.assertFalse((self.cwd / "orin.toml").exists())

    def test_diagnostics_and_json(self):
        source = self.cwd / "bad.or"
        source.write_text("function main(): void { missing(); }\n")
        result = self.run_cli("check", "bad.or", code=1)
        self.assertIn("error[E0300]", result.stderr)
        self.assertIn("^", result.stderr)
        self.assertNotIn("\x1b", result.stderr)
        result = self.run_cli("check", "bad.or", "--format=json", code=1)
        for line in result.stdout.splitlines():
            self.assertIn("code", json.loads(line))
        self.assertNotIn("\x1b", result.stdout)

    def test_library_and_path_dependency(self):
        self.run_cli("init", "shared", "--lib")
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--path", "../shared", cwd=project)
        (project / "src/main.or").write_text('import { greeting } from "shared";\nfunction main(): void { console.log(greeting()); }\n')
        self.assertIn("Hello", self.run_cli("run", cwd=project).stdout)
        self.assertIn("shared", self.run_cli("deps", cwd=project).stdout)
        self.run_cli("remove", "shared", cwd=project)
        self.run_cli("check", cwd=project, code=1)

    def test_library_check_empty_tests_and_filter(self):
        self.run_cli("init", "shared", "--lib")
        project = self.cwd / "shared"
        self.run_cli("check", cwd=project)
        self.run_cli("test", "--filter", "does-not-exist", cwd=project, code=1)
        (project / "tests/main_test.or").unlink()
        self.run_cli("test", cwd=project, code=1)
        self.run_cli("test", "--allow-empty", cwd=project)

    def test_git_lock_offline_and_failed_add_rollback(self):
        self.run_cli("init", "shared", "--lib")
        shared = self.cwd / "shared"
        for command in (["git", "init", "-q"], ["git", "add", "."],
                        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                         "commit", "-qm", "initial"]):
            subprocess.run(command, cwd=shared, check=True, capture_output=True)
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--git", str(shared), cwd=project)
        lock = (project / "orin.lock").read_bytes()
        self.run_cli("fetch", "--locked", "--offline", cwd=project)
        self.assertEqual(lock, (project / "orin.lock").read_bytes())
        before = (project / "orin.toml").read_bytes()
        self.run_cli("add", "--path", "../missing", cwd=project, code=1)
        self.assertEqual(before, (project / "orin.toml").read_bytes())

    def test_source_color_and_program_arguments(self):
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        source = project / "src/main.or"
        source.write_text('import { Host, withProcess } from "std:host";\nimport { args } from "std:process";\nfunction main(host: Host): void {\n  console.log(withProcess(host, p => args(p).join("|")));\n}\n')
        result = self.run_cli("run", "--", "--quiet", "two words", cwd=project)
        self.assertIn("--quiet|two words", result.stdout)
        source.write_text("function main(): void { missing(); }\n")
        result = self.run_cli("check", "--color=always", cwd=project, code=1)
        self.assertIn("\x1b[", result.stderr)

    def test_dependency_scope_and_conflicting_init(self):
        self.run_cli("init", "shared", "--lib")
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--path", "../shared", "--dev", cwd=project)
        (project / "src/main.or").write_text('import { greeting } from "shared";\nfunction main(): void { console.log(greeting()); }\n')
        self.run_cli("check", cwd=project, code=1)

    def test_transitive_sources_invalidate_build_cache(self):
        self.run_cli("init", "base", "--lib")
        self.run_cli("init", "shared", "--lib")
        self.run_cli("add", "--path", "../base", cwd=self.cwd / "shared")
        (self.cwd / "shared/src/module.or").write_text('export { greeting } from "base";\n')
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--path", "../shared", cwd=project)
        (project / "src/main.or").write_text('import { greeting } from "shared";\nfunction main(): void { console.log(greeting()); }\n')
        self.assertIn("Hello", self.run_cli("run", cwd=project).stdout)
        (self.cwd / "base/src/module.or").write_text('export function greeting(): string { return "Changed"; }\n')
        self.assertIn("Changed", self.run_cli("run", cwd=project).stdout)

    def test_watch_restarts_after_change_and_stops_cleanly(self):
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        log = self.cwd / "watch.log"
        with log.open("w") as output:
            process = subprocess.Popen([str(self.cli), "dev"], cwd=project,
                                       stdout=output, stderr=output, start_new_session=True)
            try:
                deadline = time.monotonic() + 30
                while "Hello from Orin!" not in log.read_text() and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertIn("Hello from Orin!", log.read_text())
                (project / "src/main.or").write_text('function main(): void { console.log("Rebuilt"); }\n')
                deadline = time.monotonic() + 30
                while "Rebuilt" not in log.read_text() and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertIn("Rebuilt", log.read_text())
            finally:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            self.assertEqual(process.returncode, 130, log.read_text())

    def test_machine_init_and_invalid_flags(self):
        result = self.run_cli("init", "hello", "--format=json")
        self.assertTrue(json.loads(result.stdout)["ok"])
        self.run_cli("run", "--format=json", cwd=self.cwd / "hello", code=2)

    def test_http_template_and_llvm_release(self):
        self.run_cli("init", "server", "--template", "http")
        self.run_cli("check", cwd=self.cwd / "server")
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("build", "--release", "--backend=llvm", cwd=project)
        binary = project / "build/release/hello"
        self.assertIn("Hello", subprocess.check_output([str(binary)], text=True))
        self.run_cli("clean", cwd=project)
        self.assertFalse(binary.exists())

    def test_absolute_dependency_from_nested_directory(self):
        self.run_cli("init", "shared", "--lib")
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--path", str(self.cwd / "shared"), cwd=project / "src")
        self.run_cli("build", cwd=project)

    def test_root_lock_pins_transitive_git_dependencies(self):
        for name in ("base", "shared"):
            self.run_cli("init", name, "--lib")
        base = self.cwd / "base"
        subprocess.run(["git", "init", "-q"], cwd=base, check=True)
        subprocess.run(["git", "add", "."], cwd=base, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "initial"], cwd=base, check=True)
        self.run_cli("add", "--git", str(base), cwd=self.cwd / "shared")
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--path", "../shared", cwd=project)
        self.assertIn("shared/base|git|", (project / "orin.lock").read_text())
        self.run_cli("fetch", "--locked", "--offline", cwd=project)

    def test_failed_git_update_restores_cached_source(self):
        self.run_cli("init", "shared", "--lib")
        shared = self.cwd / "shared"
        def git(*args):
            return subprocess.check_output(
                ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", *args],
                cwd=shared, text=True).strip()
        git("init", "-q")
        git("add", ".")
        git("commit", "-qm", "initial")
        old_commit = git("rev-parse", "HEAD")
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--git", str(shared), cwd=project)
        with (shared / "orin.toml").open("a") as manifest:
            manifest.write('\n[dependencies]\nmissing = { path = "../missing" }\n')
        git("add", ".")
        git("commit", "-qm", "broken dependency")
        self.run_cli("update", "shared", cwd=project, code=1)
        cached_commit = subprocess.check_output(
            ["git", "-C", str(project / ".orin/packages/shared"), "rev-parse", "HEAD"], text=True).strip()
        self.assertEqual(old_commit, cached_commit)

    def test_malformed_child_manifest_rolls_back_add(self):
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        bad = self.cwd / "badlib"
        (bad / "src").mkdir(parents=True)
        (bad / "src/module.or").write_text("export const value = 1;\n")
        (bad / "orin.toml").write_text('[package]\nname = "badlib"\ninvalid = true\n')
        before = (project / "orin.toml").read_bytes()
        self.run_cli("add", "--path", "../badlib", "--name", "badlib", cwd=project, code=1)
        self.assertEqual(before, (project / "orin.toml").read_bytes())
        self.assertFalse((project / "orin.lock").exists())

    def test_consumers_ignore_library_dev_dependencies(self):
        self.run_cli("init", "shared", "--lib")
        shared = self.cwd / "shared"
        with (shared / "orin.toml").open("a") as manifest:
            manifest.write('\n[dev-dependencies]\ntestkit = { path = "../absent-testkit" }\n')
        subprocess.run(["git", "init", "-q"], cwd=shared, check=True)
        subprocess.run(["git", "add", "."], cwd=shared, check=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "initial"], cwd=shared, check=True)
        self.run_cli("init", "hello")
        project = self.cwd / "hello"
        self.run_cli("add", "--git", str(shared), cwd=project)
        self.run_cli("build", cwd=project)
        self.assertNotIn("testkit", (project / "orin.lock").read_text())

    def test_shared_path_dependency_cannot_override_root_lock(self):
        for name in ("base", "shared"):
            self.run_cli("init", name, "--lib")
        base = self.cwd / "base"
        def git(*args):
            return subprocess.check_output(
                ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", *args],
                cwd=base, text=True).strip()
        git("init", "-q"); git("add", "."); git("commit", "-qm", "v1")
        self.run_cli("add", "--git", str(base), cwd=self.cwd / "shared")
        (self.cwd / "shared/src/module.or").write_text('export { greeting } from "base";\n')
        for name in ("app1", "app2"):
            self.run_cli("init", name)
            project = self.cwd / name
            self.run_cli("add", "--path", "../shared", cwd=project)
            (project / "src/main.or").write_text('import { greeting } from "shared";\nfunction main(): void { console.log(greeting()); }\n')
        self.assertIn("Hello", self.run_cli("run", cwd=self.cwd / "app1").stdout)
        (base / "src/module.or").write_text('export function greeting(): string { return "Changed"; }\n')
        git("add", "."); git("commit", "-qm", "v2")
        self.run_cli("update", cwd=self.cwd / "app2")
        result = self.run_cli("run", cwd=self.cwd / "app1", code=1)
        self.assertIn("locked", (result.stdout + result.stderr).lower())
        self.run_cli("fetch", "--locked", cwd=self.cwd / "app1")
        self.assertIn("Hello", self.run_cli("run", cwd=self.cwd / "app1").stdout)


if __name__ == "__main__":
    unittest.main()
