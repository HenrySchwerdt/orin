- **Contracts for the lexer and the parser's error recovery (ADR-0053 Addendum A).** `isEofTok` states what it computes
  (`result == match (t.kind) { KEof => true, _ => false }`), `Lexer.emit`, `Lexer.run` and `lex` guarantee a token
  stream that ends with KEof, and the `Parser` constructor requires one, so the parser's first two class invariants
  are proved. The token predicates of the parser (`isPunctTok`, `isKwTok`, ..) state that a matching token is not
  KEof; `report`, `stop` and the three recovery methods state the cursor and KEof facts they rely on (a private method
  does not get the class invariants), with loop invariants for the token scans. `Lexer.number`, `Lexer.float`,
  `Lexer.punct` and `Lexer.oxTag` get the preconditions `Lexer.string` already had and loop invariants for their digit
  scans; `indexRows` and the line-comment scan of `scanComments` get loop invariants. Contract-only, no logic change:
  `orin verify` of `compiler/syntax` goes from 271 to 238 UNKNOWN obligations (351 to 458 VERIFIED, 0 REFUTED).
