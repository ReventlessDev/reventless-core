#!/usr/bin/env node
// Moves record fields from `name: option<T>` to `name?: T`, one inventory group
// at a time, and rewrites the sites the compiler would otherwise refuse.
//
//   node scripts/refactor-option-fields.mjs --group A            # report what would change
//   node scripts/refactor-option-fields.mjs --group A --write    # apply it
//   node scripts/refactor-option-fields.mjs --group E --only Discovery.res,StateAnnotations.res:stateAnnotationSpec
//
// What it rewrites, per field of the group's records:
//   1. the declaration      `name: option<T>`        -> `name?: T`
//   2. a literal's `Some`   `name: Some(expr)`       -> `name: expr`
//   3. a literal's `None`   `name: None,` on its own line -> the line goes;
//                           inline `name: None` in `{...}` -> removed with its comma
//   4. a pattern's arm      `| {... name: Some(x) ...}` / `name: None` in a pattern
//                           -> `name: ?Some(x)` / `name: ?None`
//   5. a spread's `None`    `{...r, name: None}` clears the field, so it becomes
//                           `name: ?None` rather than going; so does a
//                           qualified `{M.name: None, ...}`, whose label carries the type
//   6. a `Some(` spanning lines is unwrapped with its trailing comma
// Text inside a string literal is left alone. After `--write` and a build,
// `--fix-build [dir]` rebuilds the root (or that build root) and prefixes `?` wherever the compiler says an
// `option` value is passed to an optional field (`name: ?value`, `?name`), until
// it names nothing more of that kind; what it prints last is left to read.
// Sites are matched by field name, so a field another record shares (`plugin`,
// `chapter`) may be rewritten where that record still uses `option`. The build
// refuses those, and the report lists every site, so read the report, apply,
// build, and revert the hunks the compiler names. Both spellings compile to the
// same sury schema, so nothing reaches the wire; `pnpm run check:graphql` proves it.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const root = path.resolve(new URL("..", import.meta.url).pathname);
const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const group = flag("--group");
const only = flag("--only")?.split(",") ?? null;
const write = args.includes("--write");
if (args.includes("--fix-build")) { fixBuild(); process.exit(0); }
if (!group) { console.error("usage: refactor-option-fields.mjs --group <A|B|C|D|E> [--only f.res,g.res] [--write]"); process.exit(2); }

const inventory = JSON.parse(
  execFileSync("node", [path.join(root, "scripts/inventory-option-fields.mjs"), "--json"], { encoding: "utf8" }),
).filter((r) => r.group === group && (!only || only.some((o) => {
  // `File.res` takes every record of the file; `File.res:type` takes that one record.
  const [file, type] = o.split(":");
  return r.file.endsWith(file) && (!type || r.type === type);
})));
if (inventory.length === 0) { console.log("nothing in that group"); process.exit(0); }

const allFiles = execFileSync("git", ["ls-files", "*.res"], { cwd: root, encoding: "utf8" }).split("\n").filter(Boolean);
const changes = []; // {file, line, kind, before, after}
const edits = new Map(); // file -> new content

const read = (f) => edits.get(f) ?? fs.readFileSync(path.join(root, f), "utf8");
const set = (f, s) => edits.set(f, s);

// 1. declarations, on the line the inventory read each one from (a file may
// declare several records of one name, one per submodule)
for (const r of inventory) {
  const lines = read(r.file).split("\n");
  const before = lines[r.line - 1];
  // `name: option<T>` -> `name?: T`, matching the brackets so a one-line record works too
  const m = new RegExp(`(?<![\\w.])${r.field}\\s*:\\s*option<`).exec(before);
  let after = before;
  if (m) {
    let depth = 1, j = m.index + m[0].length;
    for (; j < before.length && depth; j++) { if (before[j] === "<") depth++; else if (before[j] === ">" && before[j - 1] !== "=") depth--; }
    after = before.slice(0, m.index) + `${r.field}?: ` + before.slice(m.index + m[0].length, j - 1) + before.slice(j);
  }
  if (after === before) continue;
  lines[r.line - 1] = after;
  changes.push({ file: r.file, line: r.line, kind: "declaration", before: before.trim(), after: after.trim() });
  set(r.file, lines.join("\n"));
}

// Balanced-paren removal of `Some(` ... `)` starting at index i (pointing at "Some(").
const dropSome = (line, i) => {
  let depth = 0, j = i + 4;
  for (; j < line.length; j++) {
    if (line[j] === "(") depth++;
    else if (line[j] === ")" && --depth === 0) break;
  }
  if (j >= line.length) return null; // spans lines; leave to the compiler
  return line.slice(0, i) + line.slice(i + 5, j) + line.slice(j + 1);
};

// 2.–4. sites
// A record field is written after `{`, `,` or at the start of a line; `a ? b : None`
// and `let x: t = None` are not fields. Text after `//` is a comment. On a line
// with `=>`, what stands before it is a pattern and what follows is a value.
const fields = [...new Set(inventory.map((r) => r.field))];
const codePart = (line) => { const i = line.indexOf("//"); return i < 0 ? line : line.slice(0, i); };
const isFieldAt = (line, idx) => {
  const before = line.slice(0, idx).trimEnd();
  if ((line.slice(0, idx).match(/(?<!\\)["`]/g) ?? []).length % 2 === 1) return false; // in a string
  return before === "" || /[{,(]$/.test(before);
};
// Whether the record literal enclosing `idx` of `text` opens with a spread.
const inSpread = (text, idx) => {
  let depth = 0, i = idx - 1;
  for (; i >= 0; i--) {
    const c = text[i];
    if (c === "}" || c === ")" || c === "]") depth++;
    else if (c === "{" || c === "(" || c === "[") { if (depth === 0) break; depth--; }
  }
  return i >= 0 && text[i] === "{" && text.slice(i + 1).trimStart().startsWith("...");
};
const inPattern = (line, idx) => {
  const arrow = line.indexOf("=>");
  if (arrow >= 0) return idx < arrow;
  return /^\s*\|/.test(line) || /\bswitch\b/.test(line);
};
for (const f of allFiles) {
  let src = read(f);
  const lines = src.split("\n");
  let touched = false;
  for (let n = 0; n < lines.length; n++) {
    let line = lines[n];
    for (const field of fields) {
      const code = codePart(line);
      const someRe = new RegExp(`(?<![\\w.])((?:[A-Z]\\w*\\.)*)${field}\\s*:\\s*Some\\(`);
      const noneRe = new RegExp(`(?<![\\w.])((?:[A-Z]\\w*\\.)*)${field}\\s*:\\s*None\\b`);
      let m = someRe.exec(code);
      if (m && isFieldAt(code, m.index)) {
        const at = m.index + m[0].length - 5;
        const before = line;
        const after = inPattern(code, m.index) ? line.slice(0, at) + "?" + line.slice(at) : dropSome(line, at);
        if (after) { changes.push({ file: f, line: n + 1, kind: inPattern(code, m.index) ? "pattern Some" : "literal Some", before: before.trim(), after: after.trim() }); line = after; touched = true; }
        continue;
      }
      m = noneRe.exec(code);
      if (m && isFieldAt(code, m.index)) {
        const before = line;
        let after;
        // `{M.name: None, ...}` carries the record's type; dropping it would lose that.
        const qualified = m[1] !== "";
        const spread = !inPattern(code, m.index) && inSpread(lines.slice(0, n).join("\n") + "\n" + line, lines.slice(0, n).join("\n").length + 1 + m.index);
        if (inPattern(code, m.index) || spread || qualified) after = line.replace(noneRe, `$1${field}: ?None`);
        else if (new RegExp(`^\\s*${field}\\s*:\\s*None\\s*,?\\s*$`).test(code)) after = null;
        else after = line.replace(new RegExp(`\\s*${field}\\s*:\\s*None\\s*,?`), (s) => (s.trim().endsWith(",") ? " " : ""));
        changes.push({ file: f, line: n + 1, kind: inPattern(code, m.index) ? "pattern None" : spread ? "spread None" : qualified ? "qualified None" : after === null ? "literal None line" : "literal None inline", before: before.trim(), after: after === null ? "(removed)" : after.trim() });
        if (after === null) { lines.splice(n, 1); n--; touched = true; line = null; break; }
        line = after; touched = true;
      }
    }
    if (line !== null) lines[n] = line;
  }
  if (touched) set(f, lines.join("\n"));
  // 6. `name: Some(` whose closing paren is on a later line
  src = read(f);
  const multi = new RegExp(`(?<![\\w.])((?:[A-Z]\\w*\\.)*)(${fields.join("|")})\\s*:\\s*Some\\(`, "g");
  let out = "", from = 0, mm;
  while ((mm = multi.exec(src))) {
    const lineStart = src.lastIndexOf("\n", mm.index) + 1;
    const lineText = src.slice(lineStart, src.indexOf("\n", mm.index) < 0 ? src.length : src.indexOf("\n", mm.index));
    const col = mm.index - lineStart;
    if (!isFieldAt(codePart(lineText), col) || inPattern(lineText, col)) continue;
    let depth = 1, j = mm.index + mm[0].length;
    for (; j < src.length && depth; j++) {
      if ("([{".includes(src[j])) depth++; else if (")]}".includes(src[j])) depth--;
    }
    const inner = src.slice(mm.index + mm[0].length, j - 1);
    if (!inner.includes("\n")) continue;
    out += src.slice(from, mm.index) + `${mm[1]}${mm[2]}: ` + inner.trim().replace(/,$/, "");
    from = j;
    changes.push({ file: f, line: src.slice(0, mm.index).split("\n").length, kind: "literal Some, multi-line", before: `${mm[2]}: Some(…)`, after: `${mm[2]}: …` });
    multi.lastIndex = j;
  }
  if (from > 0) set(f, out + src.slice(from));
}

// report
const byKind = {};
for (const c of changes) byKind[c.kind] = (byKind[c.kind] || 0) + 1;
console.log(`group ${group}: ${inventory.length} fields in ${new Set(inventory.map((r) => r.file + r.type)).size} records; ${changes.length} edits in ${edits.size} files`);
console.log(byKind);
for (const c of changes) console.log(`${c.file}:${c.line}  [${c.kind}]\n    - ${c.before}\n    + ${c.after}`);

if (write) {
  for (const [f, s] of edits) fs.writeFileSync(path.join(root, f), s);
  console.log(`\nwrote ${edits.size} files. Build, read the compiler's refusals, revert the hunks it names, then rerun the inventory.`);
} else {
  console.log("\ndry run; pass --write to apply.");
}

// Rebuild the root and answer every "you're passing an optional value" refusal with
// `?`, and every "is not optional ... Use without ?" by taking the `?` back.
function fixBuild() {
  for (let round = 0; round < 500; round++) {
    let text = "";
    try { execFileSync("pnpm", ["exec", "rescript", "build", ...(flag("--fix-build")?.startsWith("-") === false ? [flag("--fix-build")] : [])], { cwd: root, encoding: "utf8", stdio: "pipe" }); }
    catch (e) { text = `${e.stdout ?? ""}${e.stderr ?? ""}`.replace(/\x1b\[[0-9;]*m/g, ""); }
    if (!text) { console.log(`build passes after ${round} fix(es)`); return; }
    let fixed = 0;
    for (const block of text.split("We've found a bug for you!").slice(1)) {
      const at = /(\/\S+\.res):(\d+):(\d+)/.exec(block);
      if (at && /Field \S+ is not optional in type .*Use without \?/s.test(block)) {
        const lines = fs.readFileSync(at[1], "utf8").split("\n");
        const l = Number(at[2]) - 1, c = Number(at[3]) - 1;
        const q = lines[l].lastIndexOf("?", c);
        if (q >= 0 && /^\s*$/.test(lines[l].slice(q + 1, c))) {
          lines[l] = lines[l].slice(0, q) + lines[l].slice(q + 1);
          fs.writeFileSync(at[1], lines.join("\n"));
          console.log(`${path.relative(root, at[1])}:${l + 1}  ? taken back`);
          fixed++;
        }
        continue;
      }
      if (!at || !block.includes("you're passing an optional value to it")) continue;
      const lines = fs.readFileSync(at[1], "utf8").split("\n");
      const l = Number(at[2]) - 1, c = Number(at[3]) - 1, head = lines[l].slice(0, c).trimEnd();
      if (head !== "" && !/[:,{]$/.test(head)) continue;
      lines[l] = lines[l].slice(0, c) + "?" + lines[l].slice(c);
      fs.writeFileSync(at[1], lines.join("\n"));
      console.log(`${path.relative(root, at[1])}:${l + 1}  ?-prefixed`);
      fixed++;
    }
    if (!fixed) { console.log(text.slice(-4000)); return; }
  }
}

