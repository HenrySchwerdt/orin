# Documentation index

Use current guides for supported behavior and dated evidence for the revision
it measured. An accepted design or an open optimization PR does not establish
that a feature has shipped. [Progress](progress.md) records implementation status;
[known limitations](known-limitations.md) and [assurance](assurance.md) qualify it.

## Using Orin

- [Install and packages](install.md), [project CLI](cli.md), [testing](testing.md).
- [Language specification](../spec/spec.md), [TypeScript migration guide](ts-developers.md).
- [Standard library](std.md), [capabilities and effects](capabilities.md).
- [Encoding](std-encoding.md), [URL components/query pairs](std-url.md).
- [std:meta, the annotation-processor interface (unstable, ADR-0046 S3)](std-meta.md).
- Opt-in exact JSON: [numbers](std-jsonnumber.md), [documents](std-jsonvalue.md),
  [field-path decoders](std-jsondecode.md), [pure config example](../examples/json_config.or).
  Legacy `std:json` remains separate.
- [Concurrency as implemented](concurrency.md), [OX markup](ox.md).
- [MCP](mcp.md), [semantic graph/diff](osig.md), [Windows limitations](windows.md).

## Building and assessing changes

- [Architecture](architecture.md), [bootstrap](bootstrap.md), [compiler rewrite process](rewrite.md).
- [MIR](mir.md), [contracts](contracts.md), [formal model](formal.md), [trusted computing base](tcb.md).
- [Benchmarks and methodology](benchmarks.md), [allocation census](perf/alloc-census.md).
- Test runners and CI selection are documented in [testing](testing.md);
  generated embedded sources are maintained by [embed_prelude.py](../tools/embed_prelude.py).

## Plans and decisions

- [Integrated roadmap](roadmap.md), [stdlib priorities](agent-stdlib-priorities.md).
- [Async/concurrency foundations and decision gates](roadmaps/async-concurrency.md).
- [JSON compatibility design](rfcs/json-completeness.md); consult the concrete API guides
  above for shipped functions rather than assuming every RFC proposal is implemented.
- [ADR directory](decisions): accepted decisions, amendments and explicitly open questions.
- Claude optimization PRs [#91](https://github.com/orin-lang/orin-lang/pull/91) and
  [#98](https://github.com/orin-lang/orin-lang/pull/98) are held for a benefit/cost decision
  and parked groundwork respectively at the 2026-10-16 status refresh. They are
  not merged guarantees; their descriptions preserve measurements and caveats.

## Dated release evidence

- [1.0 readiness audit](release-1.0-readiness.md): revision-specific gap assessment.
- [Completed night-shift checkpoints](release-1.0-nightshift.md).
- [macOS package rehearsal](release-macos-dryrun-2026-10-16.md): validates its named
  artifact/revision, not all later changes or promised platforms.

These reports remain historical evidence. Current release approval requires
closing the gates against the selected candidate; it is not implied by a green
older build or by the existence of this index.
