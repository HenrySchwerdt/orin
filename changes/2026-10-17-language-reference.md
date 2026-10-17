- **Normative language reference (`docs/reference/`).** Ten chapters written from the implemented language: lexical structure,
  grammar and operator precedence, types, expressions and statements, ownership/resources/capabilities/effects,
  modules/packages/preludes, annotations and contracts (ADR-0024, ADR-0046, ADR-0012), the concurrency surface
  (ADR-0017, ADR-0039), OX markup (ADR-0043, ADR-0044) and an index of every diagnostic code. Each rule cites the conformance
  tests that pin it; rules without a test are listed per chapter, and places where a guide disagrees with the compiler are
  listed in the README ("Known discrepancies"). `tools/check_reference.py` verifies that every cited test path exists.
