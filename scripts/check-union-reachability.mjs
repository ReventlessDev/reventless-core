#!/usr/bin/env node
// Fail when a generated union parser can never reach some of its constructors.
//
// sury 11.0.0-rc.0 collapses a contiguous run of two or more same-shaped object
// members into one inner dispatch block, guards that block on "is this an
// object?" rather than on the TAG it handles, and ends it by breaking out of the
// outer dispatch. Every object therefore enters the block; one carrying a TAG the
// block does not know hits its fall-through throw; and any member emitted after
// the block is unreachable. Encoding is unaffected, so values are written
// correctly and then cannot be read back. See DZakh/sury#392 and
// docs/analysis/plugin-command-union-decode-failure.md.
//
// Two properties are what make this worth running rather than testing per spec:
//
// - It reads the generated parser, not the schema. The defect is in emitted code,
//   so the emitted code is the honest place to look — and no fixture value is
//   needed, which is what lets it cover every union in the repository rather than
//   the ones someone thought to write a decode test for. Both cases outside
//   PluginSpec were found this way.
//
// - It is a shape check, not a round-trip. A union whose constructors all decode
//   today can be broken by adding one more in reading order, and nothing about
//   the declaration looks wrong. This fails on the shape, before anyone has to
//   notice.
//
// Plain .mjs rather than ReScript because it is untyped reflection throughout:
// `import` is syntax, so a computed specifier cannot be bound as an external; a
// compiled module's exports are shaped by the spec that wrote them; and the
// artifact examined is the source text of a generated function. There is no
// domain model here for types to earn their keep on.
//
// Usage: pnpm run check:unions

import * as S from "sury"
import { execSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")

// The dispatch loop, however the parser opens around it: `rc.0` emitted
// `i=>{for(;;){`, `rc.2` and `11.0.0` guard it on "is an object" first. The
// first loop is the outer dispatch; a loop inside it that tests `i`'s tag is a
// grouped block.
const LOOP = "for(;;){"

// The tags tested on the dispatched value `i` itself, in either spelling sury
// has emitted. A payload's own union dispatches on `v0.TAG`, not on `i`, and a
// test there says nothing about which of `i`'s members are reachable.
const TAG_TEST = /\bi(?:\["TAG"\]|\.TAG)==="([^"]+)"/g
const tagsIn = (src) => [...src.matchAll(TAG_TEST)].map((m) => m[1])

// Index of the `}` closing the block whose opening `{` sits at `start`.
const blockEnd = (src, start) => {
  let depth = 0
  for (let i = start; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}" && --depth === 0) return i
  }
  return src.length
}

// {grouped, reachable, stranded}: whether the outer dispatch holds a grouped
// block, and the tags tested after that block inside the outer one, which no
// value can reach.
const examine = (parser) => {
  const outer = parser.indexOf(LOOP)
  if (outer === -1) return { grouped: false, stranded: [] }
  const outerEnd = blockEnd(parser, outer + LOOP.length - 1)
  for (let at = parser.indexOf(LOOP, outer + 1); at !== -1 && at < outerEnd; ) {
    const end = blockEnd(parser, at + LOOP.length - 1)
    const inside = tagsIn(parser.slice(at, end))
    if (inside.length) {
      return {
        grouped: true,
        reachable: inside,
        stranded: tagsIn(parser.slice(end, outerEnd)),
      }
    }
    at = parser.indexOf(LOOP, end)
  }
  return { grouped: false, stranded: [] }
}

// sury exports no way to read a compiled parser since `11.0.0` dropped
// `S.parser`. A first parse compiles one and caches it on the schema as a list
// (`c`, next `n`) of operations, each with its function in `v`. Internal, so the
// run fails below when it finds none rather than passing having read nothing.
const compiledParser = (schema) => {
  try {
    S.parseOrThrow({ TAG: "" }, schema)
  } catch {}
  for (let op = schema.c; op; op = op.n) if (typeof op.v === "function") return String(op.v)
  return null
}

const files = execSync(
  `grep -rl 'Sury.union(\\[' --include='*.res.mjs' ${ROOT} | grep -v node_modules | grep -v '/lib/'`,
  { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
)
  .trim()
  .split("\n")
  .filter(Boolean)

let checked = 0
let grouped = 0
const failures = []
const unimportable = []

for (const file of files) {
  const relative = path.relative(ROOT, file)
  let mod
  try {
    mod = await import(file)
  } catch (err) {
    // Test modules need Jest globals to load and carry no published schema.
    if (!/\/tests?\//.test(file)) unimportable.push([relative, String(err.message).split("\n")[0]])
    continue
  }
  for (const [schemaName, value] of Object.entries(mod)) {
    if (!value || typeof value !== "object" || !schemaName.toLowerCase().includes("schema")) continue
    const parser = compiledParser(value)
    if (!parser || !tagsIn(parser).length) continue
    checked++
    const result = examine(parser)
    if (result.grouped) grouped++
    if (result.stranded.length) failures.push({ file: relative, schemaName, ...result })
  }
}

for (const [file, err] of unimportable) console.error(`could not load ${file}: ${err}`)

if (failures.length) {
  console.error(`\n${failures.length} union(s) have unreachable constructors:\n`)
  for (const f of failures) {
    console.error(`  ${f.file}  ${f.schemaName}`)
    console.error(`    reachable  : ${f.reachable.join(", ")}`)
    console.error(`    UNREACHABLE: ${f.stranded.join(", ")}`)
  }
  console.error(
    "\nDeclare the constructors whose payload schema contains a union (an `option`\n" +
      "or nullable field counts) ahead of the ones that group. See DZakh/sury#392.\n",
  )
  process.exit(1)
}

if (unimportable.length) process.exit(1)

// Zero examined is a guard that can no longer see sury's output (a renamed cache,
// a new tag spelling), not a repository with no unions.
if (checked === 0) {
  console.error(
    "examined 0 tagged-union parsers: this sury release compiles them in a way the guard\n" +
      "cannot read. Teach compiledParser / TAG_TEST the new shape before trusting a pass.",
  )
  process.exit(1)
}

console.log(
  `ok ${checked} tagged-union parsers examined, ${grouped} with a grouped block, every constructor reachable`,
)
