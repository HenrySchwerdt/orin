# Changelog fragments

Every change adds **one new file** here instead of editing `CHANGELOG.md`. Parallel PRs used to collide on the top of
the "Unreleased" section; separate files never conflict.

- Name: `YYYY-MM-DD-<topic>.md` (lower case; digits, `.`, `_`, `-`), e.g. `2026-10-16-changelog-fragments.md`.
- Content: the entry as a Markdown list item, exactly as it would have appeared under "Unreleased":
  `- **Short title (ADR-xxxx).** What changed, for a reader of the release notes.` Continuation lines are indented.
  No headings.
- A follow-up to your own unmerged change edits its fragment; a later change gets its own file.

`tools/changelog.py --render` prints `CHANGELOG.md` with the fragments under "Unreleased" (newest first; the release
package and the GitHub release notes use it). `tools/changelog.py --release <version>` folds them into `CHANGELOG.md`
at release time and deletes them. CI (`changes` job) runs `tools/changelog.py --check`.
