#!/usr/bin/env node
/**
 * A declared slot module must load in a browser, and must not bring its own React.
 *
 * The shell fetches the file a deployment's `uiSlotsFile` names and `import()`s
 * it straight from the served origin. There is no bundler and no import map in
 * between, so every specifier left in it has to be one a browser can resolve —
 * which, for a file served on its own, means none at all. A ReScript module is
 * bundled first (`bundle-slot-modules.mjs`); this checks the bundle it produced.
 *
 * Two ways that goes wrong, and both are silent.
 *
 * **A specifier survives.** `SlotModules.load` logs what it could not import and
 * carries on, every mode draws its own regions, and the result is
 * indistinguishable from a deployment that declared no slots. No test fails and
 * no deploy complains — the surface just quietly stops being the one somebody
 * wrote.
 *
 * **React gets bundled in.** A slot module builds its elements with the shell's
 * own `createElement`, handed to `register` as an argument, so a correct one
 * never imports React. A second copy renders fine right until a renderer calls a
 * hook, where the dispatcher belongs to the other copy and it fails — a fault
 * that appears far from its cause.
 *
 * Usage: node scripts/check-slot-modules.mjs
 */

import { readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative } from 'node:path'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

// Every file a deployment in this repo declares as its `uiSlotsFile` — the
// bundle, not the source. Listed rather than discovered: the declaration lives
// in ReScript, and a scan that tried to read it out would be a parser to keep in
// step with the language. A new example declaring one adds a line here — the
// same bargain `check-trait-pack.mjs` makes with its pairs.
const SLOT_MODULES = [
  'examples/online-shop-hybrid/seed-data/dist/storefront-slots.js',
]

// `import x from …` / `import "…"` / `export … from …` at the start of a line,
// plus `require(`. Enough for compiler output, which never hides an import
// inside a string or a comment.
const STATIC_IMPORT = /^\s*(?:import\s[^;]*?from\s*['"]([^'"]+)['"]|import\s*['"]([^'"]+)['"]|export\s[^;]*?from\s*['"]([^'"]+)['"])/gm
const REQUIRE = /\brequire\s*\(/

let failed = false

for (const relPath of SLOT_MODULES) {
  const path = join(repoRoot, relPath)
  if (!existsSync(path)) {
    console.error(
      `✗ ${relPath}\n` +
      `  declared as a slot module but not bundled. Run \`pnpm run build\` — a\n` +
      `  deployment naming a file that does not exist fails its boot.`,
    )
    failed = true
    continue
  }

  const source = readFileSync(path, 'utf8')
  const specifiers = [...source.matchAll(STATIC_IMPORT)].map((m) => m[1] ?? m[2] ?? m[3])

  if (specifiers.length > 0) {
    console.error(
      `✗ ${relPath}\n` +
      `  still imports ${specifiers.map((s) => `"${s}"`).join(', ')}.\n` +
      `  The browser imports this file straight from the served origin, with no\n` +
      `  bundler and no import map, so it can resolve none of them — the module\n` +
      `  throws at import and every mode silently draws its own regions.\n` +
      `  This is the bundle, so a surviving specifier means something was marked\n` +
      `  external in bundle-slot-modules.mjs, or could not be resolved.`,
    )
    failed = true
    continue
  }

  // Not a substring search: "react" appears in this repo's own package names.
  // What matters is a module record for React itself, which is what a bundled
  // copy leaves behind.
  if (/\b(?:from\s*['"]react['"]|require\s*\(\s*['"]react['"])/.test(source)) {
    console.error(
      `✗ ${relPath}\n` +
      `  has React bundled into it. A slot module builds its elements with the\n` +
      `  shell's own createElement, handed to \`register\`, so a correct one never\n` +
      `  imports React. A second copy renders fine until a renderer calls a hook,\n` +
      `  where the dispatcher belongs to the other copy and it fails.\n` +
      `  Usually JSX: build through \`ReventlessSlots.h\` instead.`,
    )
    failed = true
    continue
  }

  if (REQUIRE.test(source)) {
    console.error(`✗ ${relPath}\n  calls require() — not available to a browser module.`)
    failed = true
    continue
  }

  if (!/\bregister\b/.test(source) || !/^export\s*\{[^}]*\bregister\b/m.test(source)) {
    console.error(
      `✗ ${relPath}\n` +
      `  exports no \`register\`. The shell calls exactly that one export; without\n` +
      `  it the module loads and registers nothing, which it reports and survives.`,
    )
    failed = true
    continue
  }

  console.log(`ok ${relative(repoRoot, path)} — no imports, exports register`)
}

if (failed) {
  console.error('\nSlot module check failed.')
  process.exit(1)
}
