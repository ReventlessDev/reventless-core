#!/usr/bin/env node
// Moves record fields from `name: option<T>` to `name?: T`, one inventory group
// at a time, and rewrites the sites the compiler would otherwise refuse.
//
//   node scripts/refactor-option-fields.mjs --group A            # report what would change
//   node scripts/refactor-option-fields.mjs --group A --write    # apply it
//   node scripts/refactor-option-fields.mjs --group E --only Discovery.res,Pairing.res
//
// What it rewrites, per field of the group's records:
//   1. the declaration      `name: option<T>`        -> `name?: T`
//   2. a literal's `Some`   `name: Some(expr)`       -> `name: expr`
//   3. a literal's `None`   `name: None,` on its own line -> the line goes;
//                           inline `name: None` in `{...}` -> removed with its comma
//   4. a pattern's arm      `| {... name: Some(x) ...}` / `name: None` in a pattern
//                           -> `name: ?Some(x)` / `name: ?None`
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
if (!group) { console.error("usage: refactor-option-fields.mjs --group <A|B|C|D|E> [--only f.res,g.res] [--write]"); process.exit(2); }

const inventory = JSON.parse(
  execFileSync("node", [path.join(root, "scripts/inventory-option-fields.mjs"), "--json"], { encoding: "utf8" }),
).filter((r) => r.group === group && (!only || only.some((o) => r.file.endsWith(o))));
if (inventory.length === 0) { console.log("nothing in that group"); process.exit(0); }

const allFiles = execFileSync("git", ["ls-files", "*.res"], { cwd: root, encoding: "utf8" }).split("\n").filter(Boolean);
const changes = []; // {file, line, kind, before, after}
const edits = new Map(); // file -> new content

const read = (f) => edits.get(f) ?? fs.readFileSync(path.join(root, f), "utf8");
const set = (f, s) => edits.set(f, s);

// 1. declarations
for (const r of inventory) {
  let src = read(r.file);
  const decl = new RegExp(`(^[^\\n]*?\\b)${r.field}\\s*:\\s*option<([^\\n]*?)>(\\s*,?\\s*$)`, "m");
  // Only inside the declaring record: find the type and its body span.
  const typeRe = new RegExp(`^\\s*(?:type|and)\\s+${r.type}(?:<[^>]*>)?\\s*=\\s*\\{`, "m");
  const tm = typeRe.exec(src);
  if (!tm) continue;
  let depth = 0, end = -1;
  for (let i = tm.index + tm[0].length - 1; i < src.length; i++) {
    if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) { end = i; break; }
  }
  const body = src.slice(tm.index, end);
  const fm = decl.exec(body);
  if (!fm) continue;
  const before = fm[0].trim();
  const after = `${fm[1]}${r.field}?: ${fm[2]}${fm[3]}`;
  const lineNo = src.slice(0, tm.index + fm.index).split("\n").length;
  changes.push({ file: r.file, line: lineNo, kind: "declaration", before, after: after.trim() });
  set(r.file, src.slice(0, tm.index) + body.replace(fm[0], after) + src.slice(end));
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
  return before === "" || /[{,(]$/.test(before);
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
      const someRe = new RegExp(`(?<![\\w.])${field}\\s*:\\s*Some\\(`);
      const noneRe = new RegExp(`(?<![\\w.])${field}\\s*:\\s*None\\b`);
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
        if (inPattern(code, m.index)) after = line.replace(noneRe, `${field}: ?None`);
        else if (new RegExp(`^\\s*${field}\\s*:\\s*None\\s*,?\\s*$`).test(code)) after = null;
        else after = line.replace(new RegExp(`\\s*${field}\\s*:\\s*None\\s*,?`), (s) => (s.trim().endsWith(",") ? " " : ""));
        changes.push({ file: f, line: n + 1, kind: inPattern(code, m.index) ? "pattern None" : after === null ? "literal None line" : "literal None inline", before: before.trim(), after: after === null ? "(removed)" : after.trim() });
        if (after === null) { lines.splice(n, 1); n--; touched = true; line = null; break; }
        line = after; touched = true;
      }
    }
    if (line !== null) lines[n] = line;
  }
  if (touched) set(f, lines.join("\n"));
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
