#!/usr/bin/env node
/**
 * A GWT test names the values it shares, instead of defining a helper to spell them.
 *
 * The example apps' tests keep their shared values in example files — ids in
 * `tests/<Plugin>Examples.res`, a slice's own records in `<Slice>_Examples.res` —
 * so a scenario opened in the authoring form shows a chip rather than ReScript
 * text, and so the same product is spelled one way everywhere. The tests were
 * brought to that shape once; this keeps them there, because both ways of
 * leaving it are silent.
 *
 * The way back is quiet: `let pid = ProductId.make` at the top of a file is one
 * line and reads fine, and then the ids below it are helper calls rather than
 * values — invisible to the sidecar, so a scenario built on them cannot be read
 * back or edited. Forty files each defined their own before this was made
 * uniform, and `eur` meant major units in nine of them and minor units in two:
 * the same call spelling two different amounts.
 *
 * So the rule here is one rule: **a GWT file keeps no value helper it could
 * retire.** A helper whose calls all pass a name could be examples instead; one
 * called with a variable, or with a literal no `let` can bind (`pid("p-1")`),
 * could not, and stays.
 *
 * **What this does not check, on purpose: whether a literal deserves a name.**
 * That needs the field's type, resolved from the slice spec, which the authoring
 * tooling does when it proposes names. Re-deriving it here would be a second
 * implementation to keep in step with the first, and without types it cannot tell
 * a view row's `"o1"` from a `subjectRef` of `"o1"` — it would fail on correct
 * tests. Values are inline in these tests for exactly that reason: a framework
 * record's fields, and a Flow test that spans slices, have no type to resolve.
 *
 * Reads the tests' own source, not the `.gwt.json` sidecars: a sidecar expands a
 * file-local binding into every scenario that uses it, which reports one `let` as
 * five findings and points at none of them. Reading the source needs no build.
 *
 * Usage: node scripts/check-examples.mjs
 */

import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative } from 'node:path'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const examplesRoot = join(repoRoot, 'examples')

/** Every directory under `examples/` with a `rescript.json` and a `tests/`. */
const pluginsOf = root => {
  const out = []
  const walk = dir => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      if (!e.isDirectory() || e.name === 'node_modules' || e.name === 'lib') continue
      const p = join(dir, e.name)
      if (existsSync(join(p, 'rescript.json')) && existsSync(join(p, 'tests'))) out.push(p)
      else walk(p)
    }
  }
  walk(root)
  return out.sort()
}

const filesUnder = (dir, suffix) => {
  const out = []
  const walk = d => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (e.name === 'node_modules' || e.name === 'lib') continue
      const p = join(d, e.name)
      if (e.isDirectory()) walk(p)
      else if (e.name.endsWith(suffix)) out.push(p)
    }
  }
  if (existsSync(dir)) walk(dir)
  return out.sort()
}

// ── Reading a file ──────────────────────────────────────────────────────────

/**
 * A top-level `let` that binds a value constructor rather than a value: an id
 * alias (`let pid = ProductId.make`) or a money writer
 * (`let eur = amount => Reventless.Money.make(...)`).
 *
 * Deliberately narrow. A harness helper — `testContext`, `withProvider`, a
 * `trail` over states — is not a value and is meant to stay.
 */
const valueHelpersIn = source => {
  const out = []
  source.split('\n').forEach((line, i) => {
    const m = /^let\s+([a-z_][A-Za-z0-9_']*)\s*=\s*(.*)$/.exec(line)
    if (!m) return
    const [, name, rhs] = m
    if (/^[A-Z][A-Za-z0-9_.]*\.(make|makeFromString)\s*$/.test(rhs.trim()))
      out.push({ line: i + 1, name, why: 'an id constructor alias' })
    else if (/=>.*Reventless\.Money\.(make|ofMajor)/.test(rhs))
      out.push({ line: i + 1, name, why: 'a money writer' })
  })
  return out
}

/**
 * An id's value a ReScript `let` can bind, which is how the migration decides an
 * id has a name: `"p1"` yes, `"p-1"` and `"cust-1"` no.
 */
const isBindableId = arg => /^"[a-z_][A-Za-z0-9_']*"$/.test(arg)

/**
 * A money writer's arguments written out: an amount, and a currency if the helper
 * takes one. `eur(25.0)` and `money(1999.0, EUR)` yes, `eur(price)` no.
 */
const isWrittenMoney = arg =>
  arg.split(',').every(a => /^-?\d[\d_]*(\.\d+)?$/.test(a.trim()) || /^[A-Z]+$/.test(a.trim()))

/**
 * Whether a helper could be retired — every call says its value, so each one
 * could be written through the framework and named instead.
 *
 * Two calls are deliberately allowed to keep a helper alive, and both are states
 * the migration reports rather than a lapse:
 *
 * - **a variable** (`pid(id)`, `eur(price)`), where there is no literal to name;
 * - **an id whose value is not a name** (`pid("p-1")`), where a `let` cannot bind
 *   it, so the call has to stay and say the value itself.
 *
 * A helper with no calls at all is retired: nothing refers to it.
 */
const couldRetire = (source, helper) => {
  const says = helper.why.startsWith('an id') ? isBindableId : isWrittenMoney
  const calls = [...source.matchAll(new RegExp(`\\b${helper.name}\\(([^()]*)\\)`, 'g'))]
  if (calls.length === 0) return true
  return calls.every(c => says(c[1].trim()))
}

// ── The run ─────────────────────────────────────────────────────────────────

const findings = []

for (const plugin of pluginsOf(examplesRoot)) {
  const tests = join(plugin, 'tests')
  const gwtFiles = filesUnder(tests, '_GWT.res')
  if (gwtFiles.length === 0) continue

  const exampleFiles = new Set(
    filesUnder(tests, '_Examples.res').concat(filesUnder(tests, 'Examples.res')),
  )
  if (exampleFiles.size === 0) {
    findings.push(
      `${relative(repoRoot, plugin)}  has ${gwtFiles.length} GWT tests and no example file`,
    )
    continue
  }

  for (const gwt of gwtFiles) {
    if (exampleFiles.has(gwt)) continue
    const rel = relative(repoRoot, gwt)
    const source = readFileSync(gwt, 'utf8')
    for (const h of valueHelpersIn(source))
      if (couldRetire(source, h))
        findings.push(
          `${rel}:${h.line}  let ${h.name} — ${h.why}, and every call says its value. ` +
            (h.why.startsWith('an id')
              ? 'Name each one in the example file and refer to it there.'
              : 'Write each through Reventless.Money.make, in minor units.'),
        )
  }
}

if (findings.length > 0) {
  console.error(`check:examples: ${findings.length} findings\n`)
  for (const f of findings) console.error(`  ${f}`)
  console.error(
    "\nA value two tests share belongs in the plugin's example file, named for what it\n" +
      'means, and the tests refer to it by that name.',
  )
  process.exit(1)
}

console.log('ok — no GWT file keeps a value helper it could retire')
