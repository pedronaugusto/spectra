// V8's verdicts on ECMAScript patterns, for spectra's tests: `node generate.mjs > matches.json`.
// Deterministic: the same Node gives the same file. Each case is a pattern, its flags, a
// haystack, and what `RegExp.prototype.exec` finds from the start: null, or each group's span
// (the whole match first; null where a group took no part) in UTF-8 bytes, which spectra
// searches. A span that would split a surrogate pair has no UTF-8 offset and is left out.
let seed = 0x5eed1234;
function rand(n) {
  // xorshift32
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >>> 17;
  seed ^= seed << 5; seed >>>= 0;
  return seed % n;
}
const pick = (xs) => xs[rand(xs.length)];

const curated = [
  "^[a-z]+$", "^\\d{4}-\\d{2}-\\d{2}$", "^[A-Za-z0-9_'+\\-\\.]*[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\\-]*\\.)+[A-Za-z]{2,}$",
  "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", "^#?([a-f0-9]{6}|[a-f0-9]{3})$",
  "^(\\+|-)?\\d+(\\.\\d+)?$", "^[\\w.-]+$", "(a|ab)(c|bcd)(d*)", "(a*)*", "(a*)+", "(a*|b)*", "(?:(a)|b)+", "(a)|b",
  "(?<year>\\d{4})-(?<month>\\d{2})", "\\bfoo\\b", "\\Bo\\B", "^\\p{L}+$", "\\p{Lu}\\p{Ll}*", "[\\u{1F600}-\\u{1F64F}]",
  "\\u{1F600}", "😀+", "^.$", "^..$", "[^a]", "[^]", ".", "\\s+", "\\S+", "\\w+", "\\W", "\\d+", "\\D",
  "^$", "a{2,4}", "a{2,4}?", "a+?", "a*?b", "(?:ab)+", "(a|b)*c", "x*", "(?:)", "a|", "|a", "(a|)+", "(|a)+",
  "^(?:[a-z0-9-]+\\.)*[a-z0-9-]+$", "^P(?:\\d+Y)?(?:\\d+M)?(?:\\d+D)?(?:T(?:\\d+H)?(?:\\d+M)?(?:\\d+S)?)?$",
  "[\\p{L}--[a-z]]", "[\\p{L}&&\\p{Lu}]", "[\\q{abc|d}x]", "(?i:a)b", "(?m:^b)", "(?s:.)", "k", "s", "\\u212A",
  "[^\\s\\S]", "[\\s\\S]", "\\cJ", "\\x41", "\\101", "[\\b]", "\\0", "a\\nb", "^a$", "a$", "^b",
];
const haystacks = [
  "", "a", "ab", "abc", "abcd", "aaa", "aab", "b", "ba", "2026-11-10", "x 2026-11 y", "foo bar", "foobar", "a foo b",
  "user@example.com", ".a@b.co", "a..b@c.de", "ABC", "Abc", "ÉcoleÀ", "é", "K", "K", "ſ", "s", "S",
  "😀", "a😀b", "😀😀", "\n", "a\nb", "a\rb", "a b", " \t", "_x9", "P1Y2M", "PT3H", "P", "#abc", "#a1b2c3",
  "123e4567-e89b-12d3-a456-426614174000", "-1.5", "+3", "1.", "host.name-1", "abc|d", "xab", "\u0000", "A",
];
const pieces = ["a", "b", "1", "_", " ", "\n", "\r", " ", "é", "K", "K", "ſ", "😀", "-", ".", "@", "A"];
const tokens = [
  "a", "b", "k", "s", "1", ".", "^", "$", "\\d", "\\D", "\\w", "\\W", "\\s", "\\S", "\\b", "\\B", "(", ")", "(?:",
  "(?<n>", "|", "*", "+", "?", "*?", "+?", "{1,2}", "{2}", "[", "]", "[^", "-", "😀", "\\u{1F600}", "\\p{L}", "\\P{L}",
  "\\p{Lu}", "é", "\\u212A", "[a-z]", "[^a]", "[\\w-]", "(a|b)", "(a*)", "(?:a|)", "\\n", "\\r", "[\\s\\S]",
];
const flagsets = ["", "u", "v", "i", "ui", "vi", "m", "s", "um", "us", "im", "vim", "uis"];

function utf8Offset(s, i) {
  if (i > 0 && i < s.length) {
    const hi = s.charCodeAt(i - 1), lo = s.charCodeAt(i);
    if (hi >= 0xd800 && hi <= 0xdbff && lo >= 0xdc00 && lo <= 0xdfff) return null;
  }
  return Buffer.byteLength(s.slice(0, i), "utf8");
}

function verdict(re, haystack) {
  const m = re.exec(haystack);
  if (m === null) return { match: null };
  const spans = [];
  for (let g = 0; g < m.length; g++) {
    if (m[g] === undefined) { spans.push(null); continue; }
    const start = g === 0 ? m.index : (m.indices ? m.indices[g][0] : null);
    const end = g === 0 ? m.index + m[0].length : (m.indices ? m.indices[g][1] : null);
    const s = utf8Offset(haystack, start), e = utf8Offset(haystack, end);
    if (s === null || e === null) return null;
    spans.push([s, e]);
  }
  return { match: spans };
}

const cases = [];
function add(pattern, flags, haystack) {
  let re;
  try { re = new RegExp(pattern, flags + "d"); } catch { return; }
  const v = verdict(re, haystack);
  if (v === null) return;
  cases.push({ pattern, flags, haystack, match: v.match });
}

for (const p of curated) for (const f of flagsets) for (const h of haystacks) if (rand(6) === 0) add(p, f, h);
for (let n = 0; n < 6000; n++) {
  let p = "";
  const len = 1 + rand(7);
  for (let k = 0; k < len; k++) p += pick(tokens);
  let h = "";
  const hl = rand(7);
  for (let k = 0; k < hl; k++) h += pick(pieces);
  add(p, pick(flagsets), h);
}
// Lookaround: curated patterns (zod's among them), then random ones with lookarounds among the
// tokens. Drawn after the cases above, which stay as they were.
const lookCurated = [
  "^(?!\\.)(?!.*\\.\\.)([A-Za-z0-9_'+\\-\\.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\\-]*\\.)+[A-Za-z]{2,}$",
  "^(?=.{1,253}$)(?!-)[a-z0-9-]{1,63}(?<!-)(?:\\.(?!-)[a-z0-9-]{1,63}(?<!-))*$",
  "(?<=\\$)\\d+", "(?<!\\d)\\d{3}(?!\\d)", "(?=(a+))", "(?<=(\\d+)(\\d+))$", "(?<=a(?=b)b)c",
  "^(?!.*\\.\\.)[\\w.]+$", "(?<=^|,)\\w+(?=,|$)", "(?=a)(?!b)\\w", "q(?!u)", "(?<=é)x", "(?<!😀)a",
  "(?<=(a)|b)c", "(?=(?<=a)b)\\w", "(?<!a(?=b))c", "(?:(?=(\\w))\\w)+", "(?<=\\b\\w)\\w", "\\w(?=\\s|$)",
];
for (const p of lookCurated) for (const f of flagsets) for (const h of haystacks) if (rand(3) === 0) add(p, f, h);
const lookTokens = tokens.concat(["(?=", "(?!", "(?<=", "(?<!", "(?=a)", "(?<=a)", "(?!b)", "(?<!b)"]);
for (let n = 0; n < 3000; n++) {
  let p = "";
  const len = 1 + rand(7);
  for (let k = 0; k < len; k++) p += pick(lookTokens);
  let h = "";
  const hl = rand(7);
  for (let k = 0; k < hl; k++) h += pick(pieces);
  add(p, pick(flagsets), h);
}
process.stdout.write(JSON.stringify({ node: process.version, cases }, null, 0).replace(/\},\{/g, "},\n{") + "\n");
