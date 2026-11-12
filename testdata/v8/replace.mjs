// V8's verdicts on replace and split, for spectra's tests: `node replace.mjs > replace.json`.
// A dev-time tool, outside the build. Deterministic: the same Node gives the same file.
// A sample of each replace case (one template case in eight) is a pattern, its flags, a haystack, a template (or a literal, written with
// a function replacer so no `$` is read), whether every match is replaced (`g`), and the result;
// each split case a pattern, flags, haystack, a limit (null for none) and the pieces (null for
// an undefined group). Haystacks past U+FFFF go only with `u`, where V8 and spectra both read
// code points.
const patterns = [
  "a", "(a)(b)?", "(\\w+)@(\\w+)", "(?<x>\\w)(?<y>\\w)?", "(?<n>\\d)", "(?<=a)b", "b(?=c)", "(?<!a)b", "a*", "",
  "(?:)", "(\\d)", "\\b", "x|", "(a)|b", "(?<=(\\w))\\w", "\\w(?=(\\w))", "(a*)", "(?:(a)|b)+", "é", "\\s*", ".",
  "(?<=x)y|x", "^", "$", "(?=a)", "\\B",
];
const haystacks = ["", "a", "ab", "abc", "aab", "b", "bc", "a@b c@d", "1a2b3", "xy", "a b", "éa", "aaa", "a\nb", "😀a"];
const templates = ["$&", "$`", "$'", "$$", "$1", "$2", "$10", "$01", "$0", "$<x>", "$<n>", "<$1|$2>", "[$<y>]", "x", "", "$", "$9", "$<x"];
const flagsets = ["", "u", "i", "m", "s"];
const limits = [null, 0, 1, 2];

function astral(s) { return /[\u{10000}-\u{10FFFF}]/u.test(s); }
// A deterministic sample of the template cases: one in eight (xorshift32, as generate.mjs).
let seed = 0x5eed4321;
function rand(n) {
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >>> 17;
  seed ^= seed << 5; seed >>>= 0;
  return seed % n;
}

const replaces = [];
const splits = [];
for (const p of patterns) for (const f of flagsets) {
  let re;
  try { re = new RegExp(p, f); } catch { continue; }
  for (const h of haystacks) {
    if (astral(h) && !f.includes("u")) continue;
    for (const global of [false, true]) {
      const r = new RegExp(p, f + (global ? "g" : ""));
      for (const t of templates) if (rand(8) === 0) replaces.push({ pattern: p, flags: f, haystack: h, template: t, literal: false, global, out: h.replace(r, t) });
      replaces.push({ pattern: p, flags: f, haystack: h, template: "$1", literal: true, global, out: h.replace(r, () => "$1") });
    }
    for (const limit of limits) {
      const out = limit === null ? h.split(re) : h.split(re, limit);
      splits.push({ pattern: p, flags: f, haystack: h, limit, pieces: out.map((x) => x === undefined ? null : x) });
    }
  }
}
process.stdout.write(JSON.stringify({ node: process.version, replaces, splits }, null, 0).replace(/\},\{/g, "},\n{") + "\n");
