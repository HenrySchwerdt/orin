# orin-reports

Shared report primitives for first-party HTML reports (ADR-0047 section 4). A report producer builds a typed `Report` and
calls `renderReport`; it never builds HTML strings.

| File | Role |
|---|---|
| `src/model.or` | Typed model: `Status` (passed, failed, regression, improvement, unproven, timeout, skipped, info), `Card`, `Table`, `DiffTable`, `Block`, `Section`, `Report` |
| `src/components.or` | OX components: `Shell` (page shell with sidebar slot), `Page`, `CardGrid`, `Badge`, `DataTable`, `DiffView`, notices, figures, sections |
| `src/canvas.or` | `Canvas` SVG writer; a finished chart is a sealed `SvgDoc` (every string escaped by the canvas) |
| `src/numfmt.or` | Exact `%.Nf`, `%g`, `round` and thousands grouping (Orin has no fixed-precision float formatting) |
| `theme/report.css` | The design system: system font stack, light and dark through `prefers-color-scheme`, status colours, focus states, print rules. No remote fonts, images or scripts |
| `src/theme_css.or` | Generated from `theme/report.css` by `gen_theme.sh` (`<style>` takes only a static literal in OX); `--check` fails when stale |

Safety: all dynamic text reaches the page through `std:html` (escaped by construction); the only `trustHtml` call embeds a
`SvgDoc`, which only `canvas.or` can build. Pages work without JavaScript and offline. Status is always text plus an icon, never
colour alone. Tests: `orin test tooling/reports/tests/report_test.or --runtime runtime/core` (escaping, empty states, diff markers,
determinism, number formats); `tooling/benchmarks/test.sh` runs them together with the benchmark golden tests.

Using it: add `orin-reports = { path = "../reports" }` to `[dependencies]` and `import { Report, renderReport, ... } from "orin-reports";`.
Edit `theme/report.css`, then run `tooling/reports/gen_theme.sh`.
