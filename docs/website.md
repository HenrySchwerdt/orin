# Documentation website

The site at <https://orin-lang.github.io/orin-lang/> is generated from the Markdown files in this directory by
[MkDocs](https://www.mkdocs.org/) with the Material theme (versions pinned in `site/requirements.txt`). Nothing in
`docs/` is moved or rewritten for it.

Included: [getting started](getting-started.md), [install](install.md), the [tutorial](tutorial/README.md), the
[reference](reference/README.md), [stability](stability.md), [TypeScript developers](ts-developers.md),
[CLI](cli.md), [std](std.md), [concurrency](concurrency.md) and [contracts](contracts.md). The landing page is
`site/index.md`.

## Building locally

```sh
python3 -m pip install -r site/requirements.txt
python3 tools/build_site.py      # output in build/site, strict mode
```

`tools/build_site.py` copies the selected pages into `build/site-src`, rewrites links to pages that are not part of
the site into `https://github.com/orin-lang/orin-lang/blob/main/<path>` (only in the staged copy), maps `orin` code
fences to the TypeScript lexer (no Orin lexer exists), generates the navigation, and runs `mkdocs build --strict`, so
a broken link or anchor between included pages fails the build. To add a page, add it to `TOP`/`TAIL` in the script.

## Deployment

`.github/workflows/docs.yml` builds on pull requests that touch `docs/**`, `site/**`, `tools/build_site.py` or the
workflow, and builds and deploys to GitHub Pages on pushes to `main` and manual runs.

One-time repository setting (needs an admin): **Settings > Pages > Build and deployment > Source: GitHub Actions**.
Until it is set, the deploy job fails; the build job still validates the site.
