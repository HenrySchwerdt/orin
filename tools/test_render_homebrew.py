#!/usr/bin/env python3
"""Unit test for tools/render_homebrew.py (and that the rendered formula is valid Ruby when ruby exists)."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import render_homebrew as r  # noqa: E402

TEMPLATE = os.path.join(HERE, "..", "packaging", "homebrew", "orin.rb")
VER = "0.1.0-alpha.2"
DIG = {p: format(i + 1, "x") * 64 for i, p in enumerate(r.PLATFORMS)}


def sums(version=VER, skip=None, extra=""):
    lines = [f"{d}  orin-{version}-{p}.tar.gz" for p, d in DIG.items() if p != skip]
    return "\n".join(lines) + "\n" + extra


class RenderTest(unittest.TestCase):
    def setUp(self):
        with open(TEMPLATE, encoding="utf-8") as f:
            self.tpl = f.read()

    def test_renders_all_values(self):
        out = r.render(self.tpl, VER, sums())
        self.assertIn(f'version "{VER}"', out)
        for p, d in DIG.items():
            self.assertIn(f'sha256 "{d}"', out, p)
        self.assertNotRegex(out, r"@[A-Z0-9_]+@")

    def test_each_url_pairs_with_its_checksum(self):
        out = r.render(self.tpl, VER, sums())
        for p, d in DIG.items():
            i = out.index(f"orin-#{{version}}-{p}.tar.gz")
            self.assertEqual(out[i:].split('sha256 "')[1][:64], d, p)

    def test_missing_platform_fails(self):
        with self.assertRaisesRegex(ValueError, "macos-arm64"):
            r.render(self.tpl, VER, sums(skip="macos-arm64"))

    def test_other_version_in_sums_is_not_used(self):
        with self.assertRaises(ValueError):
            r.render(self.tpl, VER, sums(version="0.0.9"))

    def test_bad_digest_and_format(self):
        with self.assertRaisesRegex(ValueError, "not a sha256"):
            r.render(self.tpl, VER, sums(extra="zz  orin-x.tar.gz\n"))
        with self.assertRaisesRegex(ValueError, "expected"):
            r.render(self.tpl, VER, sums(extra="onlyonefield\n"))

    def test_conflicting_duplicate_fails(self):
        extra = f"{'e' * 64}  orin-{VER}-linux-x86_64.tar.gz\n"
        with self.assertRaisesRegex(ValueError, "conflicting"):
            r.render(self.tpl, VER, sums(extra=extra))

    def test_version_validation(self):
        for bad in ["v0.1.0", "0.1", "", "0.1.0 x", "latest"]:
            with self.assertRaises(ValueError, msg=bad):
                r.render(self.tpl, bad, sums())

    def test_leftover_placeholder_fails(self):
        with self.assertRaisesRegex(ValueError, "@NEW@"):
            r.render(self.tpl + "# @NEW@\n", VER, sums())

    def test_star_prefixed_filenames(self):
        text = sums().replace("  orin-", " *orin-")
        self.assertIn(f'version "{VER}"', r.render(self.tpl, VER, text))

    @unittest.skipUnless(shutil.which("ruby"), "ruby not installed")
    def test_rendered_formula_is_valid_ruby(self):
        out = r.render(self.tpl, VER, sums())
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "orin.rb")
            with open(p, "w", encoding="utf-8") as f:
                f.write(out)
            res = subprocess.run(["ruby", "-c", p], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            s = os.path.join(d, "SHA256SUMS")
            with open(s, "w") as f:
                f.write(sums())
            o = os.path.join(d, "orin.rb")
            self.assertEqual(r.main(["--version", VER, "--sums", s, "-o", o]), 0)
            with open(o) as f:
                self.assertIn(VER, f.read())
            self.assertEqual(r.main(["--version", "bogus", "--sums", s, "-o", o]), 1)
            self.assertEqual(r.main(["--version", VER, "--sums", os.path.join(d, "none")]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
