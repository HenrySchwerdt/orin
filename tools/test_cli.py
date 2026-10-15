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
        (package / "VERSION").write_text("test\n")
        cls.cli = package / "bin/orin"

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


if __name__ == "__main__":
    unittest.main()
