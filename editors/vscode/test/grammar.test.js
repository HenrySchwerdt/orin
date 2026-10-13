// Tokenizes Orin snippets with the real TextMate engine (vscode-textmate + vscode-oniguruma)
// and asserts the scopes of keywords, strings, comments, numbers and declarations.
// Run: `npm test` (node --test).

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vsctm = require("vscode-textmate");
const oniguruma = require("vscode-oniguruma");

const GRAMMAR_PATH = path.join(__dirname, "..", "syntaxes", "orin.tmLanguage.json");
const WASM_PATH = require.resolve("vscode-oniguruma/release/onig.wasm");

const onigLib = oniguruma
  .loadWASM(fs.readFileSync(WASM_PATH).buffer)
  .then(() => ({
    createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
    createOnigString: (s) => new oniguruma.OnigString(s),
  }));

const registry = new vsctm.Registry({
  onigLib,
  loadGrammar: async (scopeName) =>
    scopeName === "source.orin"
      ? vsctm.parseRawGrammar(fs.readFileSync(GRAMMAR_PATH, "utf8"), GRAMMAR_PATH)
      : null,
});

let grammarPromise;
function grammar() {
  grammarPromise ??= registry.loadGrammar("source.orin");
  return grammarPromise;
}

/** Tokenize `src` (multi-line aware); returns [{ text, scopes }] for every non-blank token. */
async function tokenize(src) {
  const g = await grammar();
  assert.ok(g, "grammar loaded");
  let stack = vsctm.INITIAL;
  const out = [];
  for (const line of src.split("\n")) {
    const r = g.tokenizeLine(line, stack);
    for (const t of r.tokens) {
      const text = line.substring(t.startIndex, t.endIndex);
      if (text.trim() !== "") {
        out.push({ text, scopes: t.scopes });
      }
    }
    stack = r.ruleStack;
  }
  return out;
}

/** Scopes of the first token whose text is exactly `text`. */
function scopesOf(tokens, text) {
  const t = tokens.find((x) => x.text === text);
  assert.ok(t, `token ${JSON.stringify(text)} not found in ${JSON.stringify(tokens.map((x) => x.text))}`);
  return t.scopes;
}

function assertScope(tokens, text, scope) {
  const scopes = scopesOf(tokens, text);
  assert.ok(
    scopes.some((s) => s === scope || s.startsWith(scope + ".")),
    `expected ${JSON.stringify(text)} to have scope ${scope}, got ${JSON.stringify(scopes)}`
  );
}

test("keywords", async () => {
  const t = await tokenize(
    'import { f } from "./m";\nexport function g(): void {\n  if (true) { return; } else { while (false) { break; } }\n  for (const x of xs) { continue; }\n  match (o) { None => { } }\n}'
  );
  assertScope(t, "import", "keyword.control.import.orin");
  assertScope(t, "from", "keyword.control.import.orin");
  assertScope(t, "export", "keyword.control.export.orin");
  for (const kw of ["if", "else", "while", "break", "for", "of", "continue", "return", "match"]) {
    assertScope(t, kw, "keyword.control.flow.orin");
  }
  assertScope(t, "function", "storage.type.function.orin");
  assertScope(t, "const", "storage.modifier.const.orin");
});

test("reserved words are flagged illegal", async () => {
  for (const w of ["var", "class", "interface", "enum", "new", "this", "null", "undefined", "async", "await"]) {
    const t = await tokenize(`${w} x;`);
    assertScope(t, w, "invalid.illegal.reserved.orin");
  }
});

test("function, type, const and let declaration names", async () => {
  const t = await tokenize(
    "export function area(s: Shape): int { let acc = 0; return acc; }\nexport type Point = { x: int; y: int; };\ntype Shape = Circle(int) | Empty;\nexport const MAX: int = 10;"
  );
  assertScope(t, "area", "entity.name.function.orin");
  assertScope(t, "Point", "entity.name.type.orin");
  assertScope(t, "Shape", "entity.name.type.orin");
  assertScope(t, "type", "storage.type.type.orin");
  assertScope(t, "MAX", "variable.other.constant.orin");
  assertScope(t, "acc", "variable.other.readwrite.orin");
  assertScope(t, "let", "storage.modifier.let.orin");
});

test("types and constants", async () => {
  const t = await tokenize("function f(a: int, b: usize, c: bool, d: string): Option<Result<int, string>> { return None; }");
  for (const ty of ["int", "usize", "bool", "string"]) {
    assertScope(t, ty, "support.type.primitive.orin");
  }
  assertScope(t, "Option", "support.type.builtin.orin");
  assertScope(t, "Result", "support.type.builtin.orin");
  assertScope(t, "None", "constant.language.option.orin");
  const b = await tokenize("const x = true; const y = false;");
  assertScope(b, "true", "constant.language.boolean.orin");
  assertScope(b, "false", "constant.language.boolean.orin");
});

test("numbers", async () => {
  const t = await tokenize("const a = 123;\nconst b = 0x7F;\nconst c = 0Xab;");
  assertScope(t, "123", "constant.numeric.decimal.orin");
  assertScope(t, "0x7F", "constant.numeric.hex.orin");
  assertScope(t, "0Xab", "constant.numeric.hex.orin");
});

test("strings with escapes", async () => {
  const t = await tokenize('const s = "a\\n\\t\\x41\\"\\\\ b";');
  const str = t.filter((x) => x.scopes.includes("string.quoted.double.orin"));
  assert.ok(str.length > 0, "string tokens present");
  assertScope(t, "\\n", "constant.character.escape.orin");
  assertScope(t, "\\t", "constant.character.escape.orin");
  assertScope(t, "\\x41", "constant.character.escape.orin");
  assertScope(t, '\\"', "constant.character.escape.orin");
  assertScope(t, "\\\\", "constant.character.escape.orin");
  const bad = await tokenize('const s = "\\q";');
  assertScope(bad, "\\q", "invalid.illegal.escape.orin");
  // A keyword inside a string is just string content.
  const kw = await tokenize('const s = "if while";');
  assert.ok(!kw.some((x) => x.scopes.some((s) => s.startsWith("keyword.control"))));
});

test("comments", async () => {
  const t = await tokenize("// line comment with if and 42\nconst x = 1; // trailing\n/* block\n   spanning if lines */ const y = 2;");
  const comments = t.filter((x) => x.scopes.some((s) => s.startsWith("comment.")));
  assert.ok(comments.length >= 4);
  assert.ok(
    !t.some((x) => x.text === "if" && !x.scopes.some((s) => s.startsWith("comment."))),
    "`if` appears only inside comments"
  );
  // Code after the block comment closes is tokenized normally.
  assertScope(t, "y", "variable.other.constant.orin");
  const block = t.find((x) => x.text.includes("spanning"));
  assert.ok(block.scopes.includes("comment.block.orin"));
  assert.ok(scopesOf(t, " line comment with if and 42").includes("comment.line.double-slash.orin"));
});

test("annotations", async () => {
  const t = await tokenize("@Inline\nfunction f(): void { }");
  assertScope(t, "Inline", "entity.name.function.annotation.orin");
  assertScope(t, "@", "punctuation.definition.annotation.orin");
});

test("operators and calls", async () => {
  const t = await tokenize("const r = a == b && c != d || !e ? f(1) : g.h(2) + 3 * 4;\nmatch (x) { A => 1, }\nconst p = P { ...q, y: 1 };");
  assertScope(t, "==", "keyword.operator.comparison.orin");
  assertScope(t, "&&", "keyword.operator.logical.orin");
  assertScope(t, "=>", "storage.type.function.arrow.orin");
  assertScope(t, "...", "keyword.operator.spread.orin");
  assertScope(t, "f", "entity.name.function.call.orin");
  assertScope(t, "h", "entity.name.function.call.orin");
});

test("package.json contributions point at existing files", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "package.json"), "utf8"));
  const lang = pkg.contributes.languages[0];
  assert.equal(lang.id, "orin");
  assert.deepEqual(lang.extensions, [".or"]);
  assert.ok(fs.existsSync(path.join(__dirname, "..", lang.configuration)));
  assert.ok(fs.existsSync(path.join(__dirname, "..", pkg.contributes.grammars[0].path)));
  assert.ok(pkg.contributes.configuration.properties["orin.serverPath"]);
  assert.ok(fs.existsSync(path.join(__dirname, "..", pkg.main)));
  JSON.parse(fs.readFileSync(path.join(__dirname, "..", lang.configuration), "utf8"));
});
