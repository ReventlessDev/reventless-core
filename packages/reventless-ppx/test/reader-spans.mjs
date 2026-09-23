// Checks reventless-ppx-read over examples/online-shop-hybrid
// (docs/plans/source-reader-with-spans.md, S1 and S2 exits).
//
//   node test/reader-spans.mjs <read.exe> <repo-root>
//
// Prints one "ok: …" or "FAIL: …" line per check; run.sh counts them.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const [reader, root] = process.argv.slice(2);
const app = path.join(root, "examples/online-shop-hybrid");

const walk = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) return ["node_modules", "lib"].includes(e.name) ? [] : walk(p);
    return e.name.endsWith(".res") ? [p] : [];
  });
const files = walk(app);
const marked = (attr) => files.filter((f) => fs.readFileSync(f, "utf8").includes(attr));

const read = (file) => JSON.parse(execFileSync(reader, [file], { encoding: "utf8" }));

// Spans are byte offsets, so they are cut from the file's bytes.
const cutter = (file) => {
  const bytes = fs.readFileSync(file);
  return (s) => bytes.subarray(s.start, s.end).toString("utf8");
};

const report = (label, bad) => {
  if (bad.length === 0) console.log(`ok: ${label}`);
  else console.log(`FAIL: ${label}\n  ${bad.slice(0, 10).join("\n  ")}`);
};

// ── S1: every declaration of every spec file ────────────────────────────────

{
  const specs = marked("@@reventless.spec");
  const bad = [];
  let n = 0;
  for (const file of specs) {
    const j = read(file);
    const cut = cutter(file);
    const base = path.basename(file);
    const check = (ok, what, node) => {
      n++;
      if (node.text !== cut(node.span)) bad.push(`${base}: ${what}: text is not its span`);
      else if (!ok) bad.push(`${base}: ${what} => ${JSON.stringify(node.text).slice(0, 90)}`);
    };
    const attrs = (as) =>
      as.forEach((a) =>
        check(a.text === `@${a.name}${a.args === null ? "" : `(${a.args})`}`, `@${a.name}`, a),
      );
    const field = (f) => {
      check(new RegExp(`^(@[\\s\\S]*)?(mutable\\s+)?${f.name}\\??\\s*:`).test(f.text), f.name, f);
      check(f.type.text.length > 0 && f.text.endsWith(f.type.text), `${f.name}'s type`, f.type);
      attrs(f.attributes);
    };
    for (const t of j.types) {
      check(t.text.startsWith(`type ${t.name}`) || t.text.startsWith(t.name), t.name, t);
      attrs(t.attributes);
      for (const c of t.cases ?? []) {
        check(new RegExp(`^(\\|\\s*)?(@[\\s\\S]*)?${c.name}`).test(c.text), c.name, c);
        attrs(c.attributes);
        (c.fields ?? []).forEach(field);
        (c.args ?? []).forEach((a) => check(a.text.length > 0, `${c.name} argument`, a));
      }
      (t.fields ?? []).forEach(field);
    }
  }
  report(`${specs.length} spec files: ${n} spans cut exactly their declaration`, bad);
}

// ── S2: every GWT test, with its steps ──────────────────────────────────────

{
  const gwts = marked("@@reventless.gwt");
  const bad = [];
  let tests = 0;
  for (const file of gwts) {
    const j = read(file);
    const base = path.basename(file);
    const written = (fs.readFileSync(file, "utf8").match(/^\s*test\(/gm) ?? []).length;
    const found = j.describes.flatMap((d) => d.tests);
    tests += found.length;
    if (found.length !== written) bad.push(`${base}: ${found.length} tests read, ${written} written`);
    // A test may assert without a chain (a table check), but one that calls a
    // step must have it read.
    for (const t of found)
      if (t.steps.length === 0 && /\b(given|when|then)[A-Z]\w*\(/.test(t.text))
        bad.push(`${base}: "${t.title}" has no steps`);
  }
  report(`${gwts.length} GWT files: ${tests} tests, each with its steps`, bad);
}

// Every value node of every GWT file cuts what it is: a string its quotes, a number
// its value (with its sign), a name itself, a constructor from its name. Values sit
// after non-ASCII text on the same line (`"Thanks — we have your order"`), where
// the parser's columns count UTF-16 units, not bytes.
{
  const gwts = marked("@@reventless.gwt");
  const bad = [];
  let n = 0;
  const last = (name) => name.split(".").at(-1);
  for (const file of gwts) {
    const j = read(file);
    const cut = cutter(file);
    const base = path.basename(file);
    const walk = (x) => {
      if (!x || typeof x !== "object") return;
      if (Array.isArray(x)) return x.forEach(walk);
      if (x.kind && x.span && typeof x.text === "string") {
        const t = x.text;
        let ok = t === cut(x.span);
        // A template with `${…}` reaches the tree as its constant pieces
        // (`` `hashed: `` and `}`), each spanned as written.
        if (x.kind === "string") ok &&= /^"[\s\S]*"$/.test(t) || /^[`}]|`$/.test(t);
        if (x.kind === "int" || x.kind === "float")
          ok &&= t.replace(/\s+/g, "").replace(/^-\./, "-") === x.value;
        if (x.kind === "ident") ok &&= t === x.name || t === last(x.name);
        if (x.kind === "constructor") ok &&= t.startsWith(x.name) || t.startsWith(last(x.name));
        n++;
        if (!ok) bad.push(`${base}: ${x.kind} ${JSON.stringify(t).slice(0, 60)}`);
      }
      Object.values(x).forEach(walk);
    };
    walk(j.describes);
    walk(j.lets);
  }
  report(`${gwts.length} GWT files: ${n} value spans cut exactly their value`, bad);
}

// The values the .gwt.json sidecar drops are there, as written.
{
  const file = files.find((f) => f.endsWith("/Orders_GWT.res"));
  const values = [];
  const collect = (node) => {
    if (!node || typeof node !== "object") return;
    if (node.kind === "record") for (const f of node.fields) values.push([f.name, f.value.text]);
    Object.values(node).forEach((v) => (Array.isArray(v) ? v.forEach(collect) : collect(v)));
  };
  read(file).describes.forEach(collect);
  const has = (name, text) => values.some(([n, t]) => n === name && t === text);
  const total = "Reventless.Money.make(~amount=4500.0, ~currency=Reventless.Currency.EUR)";
  report(
    "Orders_GWT: lines [dockLine, chargerLine] and a Money.make total are read",
    [
      has("lines", "[dockLine, chargerLine]") ? null : "lines missing",
      has("total", total) ? null : "total missing",
    ].filter(Boolean),
  );
}

// Every top-level let of VerifyCustomerEmail_GWT.res, with a builder's parameters.
// Defaults have a fixture of their own in run.sh: the example writes none.
{
  const file = files.find((f) => f.endsWith("/VerifyCustomerEmail_GWT.res"));
  const j = read(file);
  const cut = cutter(file);
  const bad = [];
  const source = fs.readFileSync(file, "utf8");
  const written = (source.match(/^let /gm) ?? []).length;
  if (j.lets.length !== written) bad.push(`${j.lets.length} lets read, ${written} written`);
  for (const l of j.lets) {
    if (l.text !== cut(l.span) || !l.text.startsWith(`let ${l.name}`)) bad.push(`let ${l.name}`);
    if (l.value.text !== cut(l.value.span) || !l.text.endsWith(l.value.text))
      bad.push(`let ${l.name}'s value`);
  }
  const params = (name) =>
    j.lets
      .find((l) => l.name === name)
      ?.value.params.map((p) => `${p.label}=${p.default?.text ?? ""}`)
      .join(" ");
  // `refuses` returns a function: its parameters read as one list, unlabelled first.
  for (const [name, want] of [
    ["accepts", "~recipient= ~message="],
    ["refuses", "null= ~recipient= ~message="],
  ])
    if (params(name) !== want) bad.push(`${name}'s parameters: ${params(name)}`);
  report(`VerifyCustomerEmail_GWT: ${j.lets.length} lets cut exactly, with parameters`, bad);
}
