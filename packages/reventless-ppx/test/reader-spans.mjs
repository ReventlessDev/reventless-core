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
  report(
    "Orders_GWT: lines [dockLine, chargerLine] and total eur(4500.0) are read",
    [
      has("lines", "[dockLine, chargerLine]") ? null : "lines missing",
      has("total", "eur(4500.0)") ? null : "total missing",
    ].filter(Boolean),
  );
}

// Every top-level let of PlaceOrder_GWT.res, with a builder's parameters.
{
  const file = files.find((f) => f.endsWith("/PlaceOrder_GWT.res"));
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
  const synced = j.lets.find((l) => l.name === "synced");
  const params = synced?.value.params.map((p) => `${p.label}=${p.default?.text ?? ""}`).join(" ");
  if (params !== "~id= ~name= ?price=2500.0") bad.push(`synced's parameters: ${params}`);
  report(`PlaceOrder_GWT: ${j.lets.length} lets cut exactly, with parameters and defaults`, bad);
}
