#!/usr/bin/env node
// Inventory of record fields written `name: option<...>` that could be optional
// fields (`name?: T`). Both spellings compile to the same sury schema, so the
// move is source-only; what the inventory sorts out is where absence means
// "not given" (move) and where `None` is a value the logic decides on (keep).
//
// Usage:
//   node scripts/inventory-option-fields.mjs            # markdown tables, grouped
//   node scripts/inventory-option-fields.mjs --json     # the raw rows
//
// Reads every tracked .res file outside tests/, lib/ and the documentation site.
// The grouping is a heuristic by file role; the analysis that reads this output
// is docs/analysis/option-fields-that-could-be-optional.md.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const root = path.resolve(new URL("..", import.meta.url).pathname);
const json = process.argv.includes("--json");

const files = execFileSync("git", ["ls-files", "*.res"], { cwd: root, encoding: "utf8" })
  .split("\n")
  .filter((f) => f && !f.includes("/tests/") && !f.includes("/lib/") && !f.startsWith("packages/doc"));

// A record type declaration: `type name = {` or `and name = {`, with the attributes above it.
const typeRe = /((?:^\s*@[^\n]*\n)*)^\s*(?:type|and)\s+([a-zA-Z_][\w']*)(?:<[^>]*>)?\s*=\s*\{/gm;
// A field written with an option type. `name?:` is already optional and does not match.
// An attribute is one token (`@as("X")`, `@s.matches(...)`), so a run of
// attributed fields is read field by field rather than as one.
const fieldRe = /^\s*(?:@[\w.]+(?:\([^\n]*?\))?\s+)*([a-z_][\w']*)\s*:\s*(option<[^\n,]*>)/gm;

const rows = [];
for (const file of files) {
  const src = fs.readFileSync(path.join(root, file), "utf8");
  // Doc comments carry example records; blank them so they are not read as declarations.
  const code = src.replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, " "));
  let m;
  while ((m = typeRe.exec(code))) {
    let depth = 0, end = -1;
    for (let i = typeRe.lastIndex - 1; i < code.length; i++) {
      if (code[i] === "{") depth++;
      else if (code[i] === "}" && --depth === 0) { end = i; break; }
    }
    if (end < 0) continue;
    const body = code.slice(typeRe.lastIndex, end);
    // A module type body holds `let` signatures, not fields.
    if (/^\s*let\s/m.test(body) || /^\s*module\s/m.test(body)) continue;
    let fm;
    while ((fm = fieldRe.exec(body))) {
      const line = code.slice(0, typeRe.lastIndex + fm.index + fm[0].length).split("\n").length;
      rows.push({ file, line, type: m[2], field: fm[1], inner: fm[2].replace(/\s+/g, " "), schema: /@schema/.test(m[1]) });
    }
  }
}

// Heuristic groups, by the role of the file. A: published structure; B: CLI
// args; C: JS bindings; D: deploy/runtime config built in one place; F: decision
// state, guards and test harnesses; E: everything else, case by case.
const groupOf = (file) =>
  file === "reventless/spec/src/components/Plugin.res" ? "A"
  : /\/scripts\/|CliArgs|PrepareAccounts/.test(file) ? "B"
  : /^rescript\//.test(file) ? "C"
  : /_Ops\.res|Runtime_Builder|PluginRuntime_Builder|PluginExtensionPointRuntime|AppSync_Adapter|Platform_Stack|DcbEventLogStorage_DynamoDb_Runtime|PgQueryResolver_Lambda|StateTopic_AppSync|aws\/src\/Platform\.res$|AppSync_EventsApi|generator\/Config\.res|RuntimeHints|FTPHandler|ScheduleTime|Monitoring|ResourceAttribution/.test(file) ? "D"
  : /_Decision\.res|_Guards\.res|_Rules\.res|DemoData|ShopSnapshot|Flow_GWT|Hint\.res/.test(file) ? "F"
  : "E";

if (json) {
  console.log(JSON.stringify(rows.map((r) => ({ ...r, group: groupOf(r.file) })), null, 1));
  process.exit(0);
}

const titles = {
  A: "Group A: the published plugin structure, move them",
  B: "Group B: command-line arguments, move them",
  C: "Group C: bindings to JavaScript APIs, move them",
  D: "Group D: runtime and deploy configuration built in one place, move when touched",
  E: "Group E: internal results and tool records, case by case",
  F: "Group F: decision state, guards and test harnesses, keep them",
};
const types = new Map();
for (const r of rows) {
  const k = `${r.file}|${r.type}`;
  if (!types.has(k)) types.set(k, { file: r.file, type: r.type, group: groupOf(r.file), fields: [] });
  types.get(k).fields.push(r.field);
}
console.log(`${rows.length} option fields in ${types.size} record types\n`);
for (const g of ["A", "B", "C", "D", "E", "F"]) {
  const list = [...types.values()].filter((t) => t.group === g).sort((a, b) => a.file.localeCompare(b.file));
  const n = list.reduce((a, t) => a + t.fields.length, 0);
  console.log(`### ${titles[g]} (${list.length} types, ${n} fields)\n`);
  console.log("| File | Type | Fields | Which |\n|---|---|---|---|");
  for (const t of list) {
    console.log(`| [${path.basename(t.file)}](../../${t.file}) | \`${t.type}\` | ${t.fields.length} | ${t.fields.map((f) => "`" + f + "`").join(", ")} |`);
  }
  console.log();
}
