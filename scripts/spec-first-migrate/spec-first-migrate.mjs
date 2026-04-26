#!/usr/bin/env node
// Phase 4 of plans/spec-first-split-infrastructure.md.
//
// Splits a merged DCB slice file (`X.res` with `@@reventless.spec`) into:
//   - `X.res`          — Spec only (`@@reventless.spec`)
//   - `X_<Kind>.res`   — Implementation only (`@@reventless.<kind>`)
//
// Slice folder → implementation kind:
//   StateChangeSlice/         → Behavior
//   StateViewSlice/           → Projection
//   AutomationSlice/          → Automation
//   InboundTranslationSlice/  → Translation
//   OutboundTranslationSlice/ → Translation
//
// Per-kind binding classification follows D2 in the plan.
//
// Idempotent: a file already in split form (i.e., implementation file with
// `@@reventless.<kind>`, or a Spec file containing only Spec bindings) is
// skipped.
//
// Usage:
//   node scripts/spec-first-migrate/spec-first-migrate.mjs [--dry-run] [--report path] <file-or-dir>...
//
// `<file-or-dir>` may be a single .res file or a directory; directories are
// walked recursively for .res files inside any recognised slice folder.

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

// -------------------------------------------------------------- taxonomy ----

const SLICE_KINDS = {
  StateChangeSlice: {
    implKind: 'Behavior',
    implAttr: '@@reventless.behavior',
    specBindings: new Set([
      'name', 'moduleUrl', 'Id',
      'command', 'event', 'error', 'consumedEvent', 'commandSchema',
    ]),
    implBindings: new Set([
      'state', 'initialState', 'evolve', 'decide',
    ]),
  },
  StateViewSlice: {
    implKind: 'Projection',
    implAttr: '@@reventless.projection',
    specBindings: new Set([
      'name', 'moduleUrl',
      'state', 'stateSchema', 'consumedEvent', 'config', 'subIdConfig',
    ]),
    implBindings: new Set(['project']),
  },
  StateViewSliceStream: {
    implKind: 'Projection',
    implAttr: '@@reventless.projection',
    specBindings: new Set([
      'name', 'moduleUrl',
      'state', 'stateSchema', 'consumedEvent', 'config', 'subIdConfig',
    ]),
    implBindings: new Set(['project']),
  },
  AutomationSlice: {
    implKind: 'Automation',
    implAttr: '@@reventless.automation',
    specBindings: new Set([
      'name', 'moduleUrl',
      'consumedEvent', 'todoItem', 'command',
      'maxRetries', 'heartbeatInterval', 'targetName',
    ]),
    implBindings: new Set(['collect', 'resolve', 'process']),
  },
  InboundTranslationSlice: {
    implKind: 'Translation',
    implAttr: '@@reventless.translation',
    specBindings: new Set([
      'name', 'moduleUrl',
      'externalInput', 'command', 'targetName',
    ]),
    implBindings: new Set(['translate']),
  },
  OutboundTranslationSlice: {
    implKind: 'Translation',
    implAttr: '@@reventless.translation',
    specBindings: new Set([
      'name', 'moduleUrl',
      'consumedEvent', 'outboundItem', 'inboundCommand',
      'maxRetries', 'heartbeatInterval', 'targetName',
    ]),
    implBindings: new Set(['collect', 'translate']),
  },
};

const IMPL_ATTRS = new Set([
  '@@reventless.behavior',
  '@@reventless.projection',
  '@@reventless.automation',
  '@@reventless.translation',
]);

function detectSliceKind(filePath) {
  const dir = path.dirname(path.resolve(filePath));
  const parts = dir.split(path.sep);
  for (let i = parts.length - 1; i >= 0; i--) {
    if (SLICE_KINDS[parts[i]]) return parts[i];
  }
  return null;
}

// ---------------------------------------------------------------- lexer ----
//
// Walks source character-by-character to find offsets where a new top-level
// item begins. A position p is a "top-level start" iff:
//   - p is at column 0 (preceded only by '\n' or BOF),
//   - bracket depth is 0 at p,
//   - p is not inside any string or comment,
//   - the line at p, with leading whitespace stripped, begins with one of:
//       `//`  `/*`  `@`  `%%raw`
//       `let` `and` `type` `module` `external` `open` `include` `exception`
//
// String / comment handling:
//   - "..."   regular string with `\` escape
//   - `...`   template string; `${...}` interpolations track nested braces
//   - //      line comment to next \n
//   - /* */   block comment, nests in ReScript

const TOP_KEYWORDS = ['let', 'and', 'type', 'module', 'external', 'open', 'include', 'exception'];

function lineStartsTopLevel(lineText) {
  const t = lineText; // already at column 0
  if (t.startsWith('//')) return true;
  if (t.startsWith('/*')) return true;
  if (t.startsWith('@')) return true;
  if (t.startsWith('%%raw')) return true;
  for (const kw of TOP_KEYWORDS) {
    if (t === kw) return true;
    if (t.length > kw.length && t.startsWith(kw)) {
      const c = t[kw.length];
      if (c === ' ' || c === '\t') return true;
    }
  }
  return false;
}

function findTopLevelBreaks(src) {
  const breaks = [0];
  let depth = 0;
  let strCh = null;            // '"' | '`' | null
  let escape = false;
  let tmplExprDepths = [];     // nested ${...} brace counts
  let lineCmt = false;
  let blkCmt = 0;

  function isClean() {
    return depth === 0 && strCh === null && !lineCmt && blkCmt === 0;
  }

  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    const n = src[i + 1];

    // ----- consume current state first -----
    if (lineCmt) {
      if (c === '\n') {
        lineCmt = false;
        // fall through to top-level-break check below
      } else {
        continue;
      }
    } else if (blkCmt > 0) {
      if (c === '/' && n === '*') { blkCmt++; i++; continue; }
      if (c === '*' && n === '/') { blkCmt--; i++; continue; }
      continue;
    } else if (strCh === '"') {
      if (escape) { escape = false; continue; }
      if (c === '\\') { escape = true; continue; }
      if (c === '"') strCh = null;
      continue;
    } else if (strCh === '`') {
      if (escape) { escape = false; continue; }
      if (c === '\\') { escape = true; continue; }
      if (tmplExprDepths.length > 0) {
        if (c === '{') tmplExprDepths[tmplExprDepths.length - 1]++;
        else if (c === '}') {
          tmplExprDepths[tmplExprDepths.length - 1]--;
          if (tmplExprDepths[tmplExprDepths.length - 1] === 0) tmplExprDepths.pop();
        }
        continue;
      }
      if (c === '$' && n === '{') { tmplExprDepths.push(1); i++; continue; }
      if (c === '`') strCh = null;
      continue;
    } else {
      // Not in any string/comment: handle entry into one.
      if (c === '/' && n === '/') { lineCmt = true; i++; continue; }
      if (c === '/' && n === '*') { blkCmt = 1; i++; continue; }
      if (c === '"') { strCh = '"'; continue; }
      if (c === '`') { strCh = '`'; continue; }
      if (c === '{' || c === '(' || c === '[') depth++;
      else if (c === '}' || c === ')' || c === ']') depth--;
    }

    // ----- top-level break check after a clean newline -----
    if (c === '\n' && isClean()) {
      // Find the next non-empty line at column 0.
      let j = i + 1;
      while (j < src.length && (src[j] === ' ' || src[j] === '\t' || src[j] === '\n')) j++;
      if (j >= src.length) continue;
      // j must be at the start of its line for this to be a top-level start.
      let lineStart = j;
      while (lineStart > 0 && src[lineStart - 1] !== '\n') lineStart--;
      if (lineStart !== j) continue;
      const lineEnd = src.indexOf('\n', j);
      const lineText = src.substring(j, lineEnd === -1 ? src.length : lineEnd);
      if (lineStartsTopLevel(lineText)) {
        const last = breaks[breaks.length - 1];
        if (last !== j) breaks.push(j);
      }
    }
  }

  return breaks;
}

function chunksFromSource(src) {
  const breaks = findTopLevelBreaks(src);
  const chunks = [];
  for (let k = 0; k < breaks.length; k++) {
    const start = breaks[k];
    const end = k + 1 < breaks.length ? breaks[k + 1] : src.length;
    chunks.push({ start, end, text: src.substring(start, end) });
  }
  return chunks;
}

// ---------------------------------------------------- chunk classification ----

const CHUNK_COMMENT = 'comment';
const CHUNK_DECORATOR = 'decorator';
const CHUNK_FILE_ATTR_SPEC = 'file_attr_spec';
const CHUNK_FILE_ATTR_IMPL = 'file_attr_impl';
const CHUNK_BINDING = 'binding';
const CHUNK_OPEN = 'open';
const CHUNK_BLANK = 'blank';

function classifyChunk(chunk) {
  // Find first non-whitespace line.
  const text = chunk.text;
  const firstNonBlank = text.match(/^\s*(\S)/);
  if (!firstNonBlank) return { kind: CHUNK_BLANK };
  const trimmed = text.trimStart();

  if (trimmed.startsWith('//')) return { kind: CHUNK_COMMENT };
  if (trimmed.startsWith('/*')) return { kind: CHUNK_COMMENT };

  if (trimmed.startsWith('@@')) {
    // File-level attribute. Identify reventless ones.
    if (/^@@reventless\.spec\b/.test(trimmed)) return { kind: CHUNK_FILE_ATTR_SPEC };
    for (const a of IMPL_ATTRS) {
      if (trimmed.startsWith(a)) return { kind: CHUNK_FILE_ATTR_IMPL, attr: a };
    }
    // Unknown @@ attribute: treat as decorator-ish header (rare).
    return { kind: CHUNK_DECORATOR };
  }

  if (trimmed.startsWith('@')) {
    // `@schema`, `@warning(...)`, `@s.matches(...)` etc. Always belongs with
    // the next binding.
    return { kind: CHUNK_DECORATOR };
  }

  if (trimmed.startsWith('open ') || trimmed === 'open') return { kind: CHUNK_OPEN };
  if (trimmed.startsWith('include ')) return { kind: CHUNK_OPEN };

  // let, type, module, external, exception, and, %%raw
  // Extract the binding name.
  const name = extractBindingName(trimmed);
  return { kind: CHUNK_BINDING, name };
}

function extractBindingName(trimmed) {
  // Try the common forms:
  //   let name  | let rec name  | let name: T  | let (name1, name2)
  //   type name | type rec name | and name | type name<...>
  //   module Name | module type Name | module Name: T
  //   external name : ...
  //   exception Name
  let m;
  if ((m = trimmed.match(/^let\s+(?:rec\s+)?(?:%[a-zA-Z_]+\s+)?([a-zA-Z_][a-zA-Z0-9_']*)/))) return m[1];
  if ((m = trimmed.match(/^and\s+([a-zA-Z_][a-zA-Z0-9_']*)/))) return m[1];
  if ((m = trimmed.match(/^type\s+(?:rec\s+)?([a-zA-Z_][a-zA-Z0-9_']*)/))) return m[1];
  if ((m = trimmed.match(/^module\s+(?:type\s+)?([A-Z][a-zA-Z0-9_]*)/))) return m[1];
  if ((m = trimmed.match(/^external\s+([a-zA-Z_][a-zA-Z0-9_']*)/))) return m[1];
  if ((m = trimmed.match(/^exception\s+([A-Z][a-zA-Z0-9_]*)/))) return m[1];
  return null;
}

// -------------------------------------------------- group items + classify ----

// An "item" is a sequence of preamble chunks (decorators / leading comments)
// followed by a binding chunk. Comments preceding a binding follow the
// binding (per plan §Phase 4 step 2).

function groupItems(chunks) {
  // First, split into:
  //   - header     — chunks before the first @@reventless.spec (file header)
  //   - body       — chunks after @@reventless.spec
  //   - specAttr   — the @@reventless.spec chunk itself (or null)
  // Then group body chunks into items.

  let specAttrIdx = chunks.findIndex(c => classifyChunk(c).kind === CHUNK_FILE_ATTR_SPEC);
  let header = [];
  let specAttr = null;
  let bodyChunks = chunks;

  if (specAttrIdx >= 0) {
    header = chunks.slice(0, specAttrIdx);
    specAttr = chunks[specAttrIdx];
    bodyChunks = chunks.slice(specAttrIdx + 1);
  }

  // Walk body chunks, accumulating comments/decorators; flush as preamble
  // when we hit a binding (or open/include — treated as bindings for grouping).
  const items = [];
  let preamble = [];
  for (const c of bodyChunks) {
    const cl = classifyChunk(c);
    if (cl.kind === CHUNK_COMMENT || cl.kind === CHUNK_DECORATOR) {
      preamble.push(c);
    } else if (cl.kind === CHUNK_BINDING || cl.kind === CHUNK_OPEN) {
      items.push({
        preamble,
        binding: c,
        kind: cl.kind,
        name: cl.name ?? null,
      });
      preamble = [];
    } else if (cl.kind === CHUNK_BLANK) {
      // Blank chunks attach to previous item if any (preserve trailing newlines).
      if (items.length > 0 && preamble.length === 0) {
        items[items.length - 1].trailing = (items[items.length - 1].trailing ?? '') + c.text;
      } else {
        // Otherwise carry as preamble whitespace.
        preamble.push(c);
      }
    } else if (cl.kind === CHUNK_FILE_ATTR_SPEC || cl.kind === CHUNK_FILE_ATTR_IMPL) {
      // Stray file attr in body — shouldn't happen; preserve as preamble.
      preamble.push(c);
    } else {
      preamble.push(c);
    }
  }

  // Anything left in preamble (e.g., trailing comments) is appended as a
  // pseudo-item with no binding.
  let trailing = preamble;
  return { header, specAttr, items, trailing };
}

function classifyItem(item, sliceCfg) {
  if (item.kind === CHUNK_OPEN) return 'impl';
  const n = item.name;
  if (n && sliceCfg.specBindings.has(n)) return 'spec';
  if (n && sliceCfg.implBindings.has(n)) return 'impl';
  return 'impl'; // default: anything unrecognised goes to implementation
}

function renderChunks(parts) {
  return parts.map(p => p.text).join('');
}

// ----------------------------------------------- top-level migration logic ----

function isMergedSliceFile(src) {
  // True iff the source contains @@reventless.spec as a file attribute.
  return /^[ \t]*@@reventless\.spec\b/m.test(src);
}

function isAlreadySplitImplFile(src) {
  for (const a of IMPL_ATTRS) {
    const re = new RegExp('^[ \\t]*' + a.replace(/[.@]/g, '\\$&') + '\\b', 'm');
    if (re.test(src)) return true;
  }
  return false;
}

// Pure split: takes the raw source + slice kind name, returns the two
// rendered halves plus per-item targeting info. Filesystem-free; used by
// both the CLI and the self-test harness.
export function splitSource(src, sliceKindName) {
  const cfg = SLICE_KINDS[sliceKindName];
  if (!cfg) throw new Error(`unknown slice kind: ${sliceKindName}`);

  const chunks = chunksFromSource(src);
  const { header, specAttr, items, trailing } = groupItems(chunks);
  const warnings = [];

  const specItems = [];
  const implItems = [];
  const itemReports = [];

  for (const item of items) {
    const target = classifyItem(item, cfg);
    if (item.kind === CHUNK_BINDING && item.name && !cfg.specBindings.has(item.name) && !cfg.implBindings.has(item.name)) {
      warnings.push(`unrecognised binding "${item.name}" defaulted to implementation`);
    }
    if (item.kind === CHUNK_OPEN) {
      warnings.push(`top-level "${item.binding.text.trim().split('\n')[0]}" defaulted to implementation`);
    }
    (target === 'spec' ? specItems : implItems).push(item);
    itemReports.push({ name: item.name, kind: item.kind, target });
  }

  const renderItem = (it) => renderChunks(it.preamble) + it.binding.text + (it.trailing ?? '');

  const specOut = normaliseTrailingNewline(
    renderChunks(header) +
    (specAttr ? specAttr.text : '@@reventless.spec\n\n') +
    specItems.map(renderItem).join('') +
    renderChunks(trailing)
  );

  const implOut = normaliseTrailingNewline(
    cfg.implAttr + '\n\n' +
    implItems.map(renderItem).join('')
  );

  return {
    sliceKind: sliceKindName,
    implKind: cfg.implKind,
    specOut,
    implOut,
    items: itemReports,
    warnings,
  };
}

function migrateOne(filePath) {
  const sliceKind = detectSliceKind(filePath);
  if (!sliceKind) return { filePath, status: 'skipped', reason: 'not in a recognised slice folder' };

  const cfg = SLICE_KINDS[sliceKind];
  const src = fs.readFileSync(filePath, 'utf8');

  if (isAlreadySplitImplFile(src)) {
    return { filePath, status: 'skipped', reason: 'already split (impl file)' };
  }
  if (!isMergedSliceFile(src)) {
    return { filePath, status: 'skipped', reason: 'no @@reventless.spec attribute' };
  }

  const stem = path.basename(filePath, '.res');
  if (stem.endsWith('_' + cfg.implKind)) {
    return { filePath, status: 'skipped', reason: 'filename already has _' + cfg.implKind + ' suffix' };
  }

  const dir = path.dirname(filePath);
  const implPath = path.join(dir, `${stem}_${cfg.implKind}.res`);

  if (fs.existsSync(implPath)) {
    return { filePath, status: 'skipped', reason: `implementation file already exists at ${path.relative(process.cwd(), implPath)}` };
  }

  const split = splitSource(src, sliceKind);

  return {
    filePath,
    status: 'migrate',
    sliceKind,
    implKind: split.implKind,
    specPath: filePath,
    implPath,
    specOut: split.specOut,
    implOut: split.implOut,
    items: split.items,
    warnings: split.warnings,
  };
}

export { SLICE_KINDS };

function normaliseTrailingNewline(s) {
  // Always end with exactly one newline.
  let out = s.replace(/\n+$/, '\n');
  if (!out.endsWith('\n')) out += '\n';
  return out;
}

// ------------------------------------------------------------------ CLI ----

function walkResFiles(targetPath, accum) {
  const stat = fs.statSync(targetPath);
  if (stat.isFile()) {
    if (targetPath.endsWith('.res')) accum.push(path.resolve(targetPath));
    return;
  }
  if (stat.isDirectory()) {
    const base = path.basename(targetPath);
    if (base === 'node_modules' || base === 'lib') return;
    for (const entry of fs.readdirSync(targetPath)) {
      walkResFiles(path.join(targetPath, entry), accum);
    }
  }
}

function parseArgs(argv) {
  const opts = { dryRun: false, reportPath: null, targets: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dry-run' || a === '-n') opts.dryRun = true;
    else if (a === '--report') { opts.reportPath = argv[++i]; }
    else if (a === '--help' || a === '-h') { printUsage(); process.exit(0); }
    else if (a.startsWith('-')) { console.error(`unknown flag: ${a}`); process.exit(2); }
    else opts.targets.push(a);
  }
  if (opts.targets.length === 0) { printUsage(); process.exit(2); }
  return opts;
}

function printUsage() {
  console.error('Usage: spec-first-migrate.mjs [--dry-run] [--report path] <file-or-dir>...');
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const files = [];
  for (const t of opts.targets) walkResFiles(t, files);

  const report = { dryRun: opts.dryRun, results: [] };
  let migrated = 0, skipped = 0, errored = 0;

  for (const f of files) {
    let r;
    try {
      r = migrateOne(f);
    } catch (e) {
      r = { filePath: f, status: 'error', reason: e.message };
      errored++;
    }

    if (r.status === 'migrate') {
      const rel = path.relative(process.cwd(), r.filePath);
      const relImpl = path.relative(process.cwd(), r.implPath);
      console.log(`${opts.dryRun ? '[dry-run] would split' : 'split'} ${rel}`);
      console.log(`         spec  → ${rel}`);
      console.log(`         impl  → ${relImpl}  (${r.implKind})`);
      for (const w of r.warnings) console.log(`         ! ${w}`);
      if (!opts.dryRun) {
        fs.writeFileSync(r.specPath, r.specOut);
        fs.writeFileSync(r.implPath, r.implOut);
      }
      migrated++;
      report.results.push({
        file: rel,
        status: r.status,
        sliceKind: r.sliceKind,
        implKind: r.implKind,
        implPath: relImpl,
        items: r.items,
        warnings: r.warnings,
      });
    } else if (r.status === 'skipped') {
      const rel = path.relative(process.cwd(), r.filePath);
      console.log(`skip  ${rel}  — ${r.reason}`);
      skipped++;
      report.results.push({ file: rel, status: 'skipped', reason: r.reason });
    } else {
      const rel = path.relative(process.cwd(), r.filePath);
      console.error(`ERROR ${rel}  — ${r.reason}`);
      report.results.push({ file: rel, status: 'error', reason: r.reason });
    }
  }

  console.log('');
  console.log(`Summary: ${migrated} ${opts.dryRun ? 'would migrate' : 'migrated'}, ${skipped} skipped, ${errored} errored.`);

  if (opts.reportPath) {
    fs.writeFileSync(opts.reportPath, JSON.stringify(report, null, 2));
    console.log(`Report written to ${opts.reportPath}`);
  }

  process.exit(errored > 0 ? 1 : 0);
}

// Only run main when invoked directly (not when imported by tests).
import { fileURLToPath } from 'node:url';
if (process.argv[1] && process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
