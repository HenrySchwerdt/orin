#!/usr/bin/env python3
"""Changelog fragments: every change adds one file changes/<YYYY-MM-DD>-<topic>.md instead of editing CHANGELOG.md.

Parallel PRs used to collide on the top of the "Unreleased" section; separate files never conflict.

  tools/changelog.py --check             validate the fragments (CI, `changes` job)
  tools/changelog.py --render [-o FILE]  CHANGELOG.md with the fragments under "## Unreleased" (newest first)
  tools/changelog.py --release VERSION [--date YYYY-MM-DD]
                                         fold the fragments into CHANGELOG.md as "## VERSION (date)" and delete them
  tools/changelog.py --selftest

A fragment is Markdown: one or more list items, the first line starting with "- " (continuation lines indented).
Files whose name starts with "README" or "." are not fragments.
"""
import argparse, datetime, os, re, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = re.compile(r"^\d{4}-\d{2}-\d{2}-[a-z0-9][a-z0-9._-]*\.md$")


def fragments(d):
    if not os.path.isdir(d):
        return []
    return sorted(f for f in os.listdir(d) if f.endswith(".md") and not f.startswith((".", "README")))


def check(d):
    errs = []
    for f in fragments(d):
        text = open(os.path.join(d, f), encoding="utf-8").read()
        if not NAME.match(f):
            errs.append("%s: name must be YYYY-MM-DD-<topic>.md (lower case, digits, . _ -)" % f)
        if not text.strip():
            errs.append("%s: empty" % f)
        elif not text.lstrip("\n").startswith("- "):
            errs.append("%s: must start with a list item ('- ')" % f)
        elif re.search(r"^#", text, re.M):
            errs.append("%s: no headings in a fragment" % f)
    return errs


def body(d):
    # newest first, like the hand-written section was
    return "".join(open(os.path.join(d, f), encoding="utf-8").read().strip("\n") + "\n" for f in reversed(fragments(d)))


def render(changelog, d):
    text = open(changelog, encoding="utf-8").read()
    m = re.search(r"^## Unreleased[^\n]*\n", text, re.M)
    if not m:
        raise SystemExit("CHANGELOG.md has no '## Unreleased' heading")
    # drop the pointer line(s) to changes/ that stand in for the fragments
    rest = re.sub(r"\A(?:<!--.*?-->\n|\n)*", "", text[m.end():], flags=re.S)
    return text[:m.end()] + body(d) + rest


def release(changelog, d, version, date):
    text = render(changelog, d)
    text = re.sub(r"^## Unreleased[^\n]*\n", "## Unreleased\n" + POINTER + "\n## %s (%s)\n" % (version, date), text, count=1, flags=re.M)
    open(changelog, "w", encoding="utf-8").write(text)
    for f in fragments(d):
        os.remove(os.path.join(d, f))


POINTER = "<!-- Unreleased changes live in changes/*.md (one file per change, see changes/README.md); tools/changelog.py --render shows them here. -->\n"


def selftest():
    fails = 0
    with tempfile.TemporaryDirectory() as t:
        cl, d = os.path.join(t, "CHANGELOG.md"), os.path.join(t, "changes")
        os.mkdir(d)
        open(cl, "w").write("# Changelog\n\n## Unreleased\n" + POINTER + "- old unreleased entry\n\n## 0.1.0 (2026-01-01)\n- first\n")
        open(os.path.join(d, "README.md"), "w").write("# how\n")
        open(os.path.join(d, "2026-10-16-a.md"), "w").write("- **A.** first change\n  continued\n")
        open(os.path.join(d, "2026-10-17-b.md"), "w").write("- **B.** second change\n")
        def expect(cond, msg):
            nonlocal fails
            if not cond:
                fails += 1
                print("FAIL:", msg)
        expect(check(d) == [], "valid fragments pass: %r" % check(d))
        r = render(cl, d)
        expect(r.index("**B.**") < r.index("**A.**") < r.index("old unreleased") < r.index("## 0.1.0"), "render order: %r" % r)
        expect(POINTER not in r, "render drops the pointer")
        open(os.path.join(d, "bad.md"), "w").write("text without list\n")
        open(os.path.join(d, "2026-10-18-c.md"), "w").write("## heading\n")
        errs = check(d)
        expect(len(errs) == 3, "three errors (name, no list item x2): %r" % errs)
        os.remove(os.path.join(d, "bad.md")); os.remove(os.path.join(d, "2026-10-18-c.md"))
        release(cl, d, "0.2.0", "2026-10-20")
        out = open(cl).read()
        expect(out.startswith("# Changelog\n\n## Unreleased\n" + POINTER + "\n## 0.2.0 (2026-10-20)\n- **B.**"), "release heading: %r" % out[:200])
        expect("old unreleased entry" in out.split("## 0.1.0")[0], "hand-written unreleased entries are kept in the release")
        expect(fragments(d) == [], "release deletes fragments")
        expect(os.path.exists(os.path.join(d, "README.md")), "release keeps README")
    print("changelog selftest: %s" % ("ok" if fails == 0 else "%d failed" % fails))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--render", action="store_true")
    g.add_argument("--release", metavar="VERSION")
    g.add_argument("--selftest", action="store_true")
    ap.add_argument("-o", dest="out")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--root", default=ROOT)
    a = ap.parse_args()
    cl, d = os.path.join(a.root, "CHANGELOG.md"), os.path.join(a.root, "changes")
    if a.selftest:
        return selftest()
    if a.check:
        errs = check(d)
        for e in errs:
            print("changes/" + e, file=sys.stderr)
        print("changelog: %d fragments, %d errors" % (len(fragments(d)), len(errs)))
        return 1 if errs else 0
    if a.render:
        text = render(cl, d)
        if a.out:
            open(a.out, "w", encoding="utf-8").write(text)
        else:
            sys.stdout.write(text)
        return 0
    release(cl, d, a.release, a.date)
    return 0


if __name__ == "__main__":
    sys.exit(main())
