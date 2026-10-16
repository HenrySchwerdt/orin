- **Changelog fragments.** Unreleased entries are now one file per change in `changes/` (`YYYY-MM-DD-<topic>.md`, a
  Markdown list item) instead of edits to the top of `CHANGELOG.md`, so parallel PRs no longer conflict there.
  `tools/changelog.py --check | --render | --release <version> | --selftest`; the CI `changes` job checks the
  fragments, `tools/package.sh` ships the rendered changelog and the release notes use it.
