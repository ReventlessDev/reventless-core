// Sync generator for the D2 semantic class block (d2-styling-single-source plan).
// D2 consumers need an inline copy of the class block so bundles never depend on the
// docs package — but that copy is a GENERATED artifact, not a hand-maintained mirror.
// This script:
//
//   1. reads the canonical palette `packages/doc/d2/reventless.d2` (this repo),
//   2. extracts the subset of classes the graph views use (SHARED_CLASSES),
//   3. appends the tooling-only classes that have no docs counterpart (TOOLING_ONLY),
//   4. serialises a deterministic `classes: { … }` block, and
//   5. writes it into the committed `src/D2Classes.res`.
//
// Workflow: edit a SHARED class in reventless.d2 (or a tooling-only class below),
// then `pnpm sync:d2-styles`. CI/test runs `--check` (regenerate in memory, compare
// to the committed file) via tests/D2ClassesGenTest.res. The canonical palette lives
// in THIS repo, so a missing file is a hard error, not a soft skip.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// import.meta.url (not import.meta.dirname): the module is also imported by the jest
// check test, whose vm-modules context doesn't provide import.meta.dirname.
const HERE = dirname(fileURLToPath(import.meta.url));
const CANONICAL = join(HERE, "..", "..", "..", "packages", "doc", "d2", "reventless.d2");
const OUTPUT = join(HERE, "..", "src", "D2Classes.res");

// Classes pulled verbatim (by value) from the canonical palette. Order here is the
// order they appear in the generated block. Adding a class the views need = add its
// name here; if it's missing from canonical, generation fails loudly.
const SHARED_CLASSES = [
  "command",
  "msg-event",
  "aggregate",
  "state-change-slice",
  "read-model",
  "state-view-slice",
  "automation-slice",
  "side-effect",
  "extension-point",
  "extension",
  "external-system",
];
const SHARED_CONNECTIONS = ["command-flow", "event-flow", "projection-flow", "cross-plugin"];

// Tooling-only classes: used by the graph views, absent from the docs palette (they
// have no canonical counterpart, so nothing to sync against). Authored here.
const TOOLING_ONLY = {
  boundary: { style: { fill: "#BAE6FD", stroke: "#0284C7", "font-color": "#0C4A6E", "border-radius": "6" } },
  box: { style: { fill: "#F3F4F6", stroke: "#6B7280", "font-color": "#1F2937", "border-radius": "6" } },
  chapter: {
    style: { fill: "#E0E7FF", stroke: "#4F46E5", "font-color": "#3730A3", "border-radius": "8", "stroke-dash": "3" },
  },
  // Write-side slice box (event-graph): wraps one Aggregate / StateChangeSlice together
  // with its command(s) + emitted event(s) — the classic event-modeling vertical slice.
  // Echoes the amber write-side colour family (vs the indigo chapter band) and is SOLID,
  // not dashed, so a slice box reads distinctly from the chapter sub-container it nests in.
  "write-side": {
    style: { fill: "#FEFCE8", stroke: "#CA8A04", "font-color": "#713F12", "border-radius": "10" },
  },
  // Read-side slice box (event-graph): the mirror of `write-side`, wrapping one
  // ReadModel / StateViewSlice together with the event(s) it projects — the read-side
  // vertical slice. Teal/emerald family echoing the green `read-model` node (vs the amber
  // write-side), SOLID so it reads distinctly from the dashed chapter band it nests in.
  "read-side": {
    style: { fill: "#ECFDF5", stroke: "#0D9488", "font-color": "#134E4A", "border-radius": "10" },
  },
  // Board-status overlays for slice boxes (event-modeling Kanban). The box's family base
  // class (`write-side`/`read-side`) is the `Created` look; these recolour it as the
  // slice's board status advances. `InProgress` = a bold blue border (active work);
  // `Done` = a green fill + green border (ready / synthesised). Family identity is still
  // carried by the anchor node inside the box, so only the status needs to read off the box.
  "slice-inprogress": {
    style: { fill: "#EFF6FF", stroke: "#2563EB", "font-color": "#1E3A8A", "border-radius": "10", "stroke-width": "2" },
  },
  "slice-done": {
    style: { fill: "#DCFCE7", stroke: "#16A34A", "font-color": "#14532D", "border-radius": "10" },
  },
  // DCB read-edge (Phase 6.6): a consumedEvent read of a consistency boundary —
  // violet + dashed, distinct from the orange emit/event flow. The core graph omits
  // write-side DCB reads, so the graph views derive + draw these.
  "dcb-read": { style: { stroke: "#7C3AED", "font-color": "#7C3AED", "stroke-dash": "2" } },
  // DCB cross-partition read-edge (Phase 6.8): a consumedEvent read that crosses
  // partitions (an M:N invariant read). Hotter fuchsia + a longer dash so the
  // boundary-crossing reads stand out from the same-partition violet dcb-read.
  "dcb-read-xp": { style: { stroke: "#C026D3", "font-color": "#C026D3", "stroke-dash": "4" } },
};

// Full emission order: node classes, then tooling-only, then connections — mirroring
// the historical inline layout.
const ORDER = [...SHARED_CLASSES, ...Object.keys(TOOLING_ONLY), ...SHARED_CONNECTIONS];

// ── A tiny D2 `classes: { … }` parser ───────────────────────────────────────────
// Strips `#`..eol comments (but NOT a `#` inside quotes — hex colours like "#DBEAFE"
// must survive), brace-matches each `name: { … }` class body, and pulls out `shape:`
// plus every `style: { … }` entry. Style bodies never nest braces; class bodies do.

const stripComments = (s) => {
  let out = "";
  let inStr = false;
  let comment = false;
  for (const ch of s) {
    if (comment) {
      if (ch === "\n") {
        comment = false;
        out += ch;
      }
    } else if (ch === '"') {
      inStr = !inStr;
      out += ch;
    } else if (ch === "#" && !inStr) {
      comment = true;
    } else {
      out += ch;
    }
  }
  return out;
};

const collapseWs = (s) => s.replace(/\s+/g, " ").trim();

const matchBrace = (s, open) => {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === "{") depth++;
    else if (s[i] === "}") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
};

const unquote = (s) => {
  const t = s.trim();
  return (t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))
    ? t.slice(1, -1)
    : t;
};

// → Map<className, { shape?: string, style: Record<string,string> }>
const parseClasses = (src) => {
  const s = stripComments(src);
  const out = new Map();
  const ci = s.indexOf("classes");
  if (ci === -1) return out;
  const oo = s.indexOf("{", ci);
  const oc = matchBrace(s, oo);
  if (oo === -1 || oc === -1) return out;
  const body = s.slice(oo + 1, oc);
  let cursor = 0;
  while (true) {
    const open = body.indexOf("{", cursor);
    if (open === -1) break;
    const header = body.slice(cursor, open);
    const colon = header.lastIndexOf(":");
    const name = unquote(colon === -1 ? header : header.slice(0, colon));
    const close = matchBrace(body, open);
    if (close === -1) break;
    const cb = collapseWs(body.slice(open + 1, close));
    const def = { style: {} };
    const sm = cb.match(/shape\s*:\s*([^;{}\s]+)/);
    if (sm) def.shape = sm[1];
    const stIdx = cb.indexOf("style");
    if (stIdx !== -1) {
      const so = cb.indexOf("{", stIdx);
      const sc = cb.indexOf("}", so);
      if (so !== -1 && sc !== -1) {
        for (const entry of cb.slice(so + 1, sc).split(";")) {
          const kv = entry.trim();
          if (!kv) continue;
          const c = kv.indexOf(":");
          if (c === -1) continue;
          def.style[kv.slice(0, c).trim()] = unquote(kv.slice(c + 1));
        }
      }
    }
    out.set(name, def);
    cursor = close + 1;
  }
  return out;
};

// ── Deterministic serialisation ──────────────────────────────────────────────────
const STYLE_ORDER = ["fill", "stroke", "font-color", "border-radius", "stroke-dash", "opacity"];
const isNumeric = (v) => /^-?\d+(\.\d+)?$/.test(v);
const quoteName = (n) => (/^[A-Za-z0-9_]+$/.test(n) ? n : `"${n}"`);
const renderVal = (v) => (isNumeric(v) ? v : `"${v}"`);

const serializeClass = (name, def) => {
  const parts = [];
  if (def.shape) parts.push(`shape: ${def.shape}`);
  const keys = [
    ...STYLE_ORDER.filter((k) => k in def.style),
    ...Object.keys(def.style)
      .filter((k) => !STYLE_ORDER.includes(k))
      .sort(),
  ];
  if (keys.length) {
    parts.push(`style: { ${keys.map((k) => `${k}: ${renderVal(def.style[k])}`).join("; ")} }`);
  }
  return `  ${quoteName(name)}: { ${parts.join("; ")} }`;
};

// Build the `classes: { … }` block from a canonical reventless.d2 source string.
export const buildClasses = (canonicalSrc) => {
  const parsed = parseClasses(canonicalSrc);
  const lines = ["classes: {"];
  for (const name of ORDER) {
    const def = TOOLING_ONLY[name] ?? parsed.get(name);
    if (!def) {
      throw new Error(
        `d2-classes-gen: class "${name}" not found in canonical reventless.d2 and is not tooling-only`,
      );
    }
    lines.push(serializeClass(name, def));
  }
  lines.push("}");
  return lines.join("\n");
};

// ── Single-sourced shape colours ─────────────────────────────────────────────────
// Extension points / extensions render as custom node-level `shape: image` SVGs (a
// two-sided socket + a plug — d2 ignores `shape:` on a hyphenated class name). The SVGs
// are assembled per node in src/D2Shapes.res (so the label can be baked inside the
// shape); only the COLOURS need to flow from the canonical palette, so we emit them as
// constants here. Geometry + text live in D2Shapes (structural, not a drift risk).
const shapeColor = (parsed, className, key, fallback) => parsed.get(className)?.style[key] ?? fallback;

export const buildShapeColors = (canonicalSrc) => {
  const p = parseClasses(canonicalSrc);
  return {
    epFill: shapeColor(p, "extension-point", "fill", "#FFFFFF"),
    epStroke: shapeColor(p, "extension-point", "stroke", "#000000"),
    epFont: shapeColor(p, "extension-point", "font-color", "#000000"),
    extFill: shapeColor(p, "extension", "fill", "#FFFFFF"),
    extStroke: shapeColor(p, "extension", "stroke", "#000000"),
    extFont: shapeColor(p, "extension", "font-color", "#000000"),
  };
};

// Per-class swatch colour for the Event Graph legend (the saturated `stroke`, the most
// recognisable token; falls back to `fill`). Single-sourced from the same palette so the
// legend swatches never drift from the rendered shapes/edges.
export const buildSwatchColors = (canonicalSrc) => {
  const parsed = parseClasses(canonicalSrc);
  const out = {};
  for (const name of ORDER) {
    const def = TOOLING_ONLY[name] ?? parsed.get(name);
    if (!def) continue;
    out[name] = def.style["stroke"] ?? def.style["fill"] ?? "#6B7280";
  }
  return out;
};

// The full generated ReScript module. The class block contains `"` and `#` but no
// backticks or `${`, so it embeds in a template literal verbatim; the colour constants
// are plain hex strings. `renderModule` is the single source the check test compares
// the committed file against.
export const renderModule = (canonicalSrc) => {
  const block = buildClasses(canonicalSrc);
  const c = buildShapeColors(canonicalSrc);
  const sw = buildSwatchColors(canonicalSrc);
  const swatchArms = Object.entries(sw)
    .map(([k, v]) => `  | ${JSON.stringify(k)} => ${JSON.stringify(v)}`)
    .join("\n");
  return `// GENERATED FILE — do not edit by hand.
// The semantic D2 class block + single-sourced extension-point/extension shape colours,
// shared by every D2 graph view over the protocol model. Source of truth: shared classes +
// colours come from packages/doc/d2/reventless.d2 (this repo); tooling-only classes
// (boundary/box/chapter/slices) live in scripts/d2-classes-gen.mjs; the socket/plug
// geometry lives in src/D2Shapes.res. Regenerate with \`pnpm sync:d2-styles\`; verified by
// tests/D2ClassesGenTest.res.
let classes = \`${block}\`

// Single-sourced colours for the custom extension-point (socket) / extension (plug)
// shapes — consumed by D2Shapes.res, which bakes the label into the SVG per node.
let extensionPointFill = "${c.epFill}"
let extensionPointStroke = "${c.epStroke}"
let extensionPointFontColor = "${c.epFont}"
let extensionFill = "${c.extFill}"
let extensionStroke = "${c.extStroke}"
let extensionFontColor = "${c.extFont}"

// Per-class swatch colour for the Event Graph legend (see buildSwatchColors).
let swatchColor = (cls: string): string =>
  switch cls {
${swatchArms}
  | _ => "#6B7280"
  }
`;
};

// ── CLI: default writes; --check verifies (exit 1 on drift) ──────────────────────
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const check = process.argv.includes("--check");
  const canonical = readFileSync(CANONICAL, "utf8"); // same-repo: missing = hard error
  const content = renderModule(canonical);
  if (check) {
    let current = "";
    try {
      current = readFileSync(OUTPUT, "utf8");
    } catch {
      /* missing output ⇒ treated as drift below */
    }
    if (current !== content) {
      console.error("[d2-classes-gen] src/D2Classes.res is out of date — run `pnpm sync:d2-styles`");
      process.exit(1);
    }
    console.log("[d2-classes-gen] src/D2Classes.res is in sync");
  } else {
    writeFileSync(OUTPUT, content);
    console.log(`[d2-classes-gen] wrote ${OUTPUT}`);
  }
}
