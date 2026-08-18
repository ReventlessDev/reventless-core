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

const OUTER_DISPATCH = "i=>{for(;;){"
const GROUP_MARKER = "){for(;;){"

// Constructor names are ReScript identifiers, so a quote always closes one.
const tagsIn = (src) =>
  src
    .split('["TAG"]==="')
    .slice(1)
    .map((part) => part.slice(0, part.indexOf('"')))
    .filter(Boolean)

// Index of the `}` closing the block whose opening `{` sits at `start`.
const blockEnd = (src, start) => {
  let depth = 0
  for (let i = start; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}" && --depth === 0) return i
  }
  return src.length
}

// {reachable, stranded} when a grouped block is followed by further members.
const strandedAfterGroup = (parser) => {
  const outer = parser.indexOf(OUTER_DISPATCH)
  if (outer === -1) return null
  const group = parser.indexOf(GROUP_MARKER, outer + 5)
  if (group === -1) return null

  const end = blockEnd(parser, group + GROUP_MARKER.length - 1)
  const stranded = tagsIn(parser.slice(end))
  return stranded.length ? { reachable: tagsIn(parser.slice(group, end)), stranded } : null
}

const files = execSync(
  `grep -rl 'Sury.union(\\[' --include='*.res.mjs' ${ROOT} | grep -v node_modules | grep -v '/lib/'`,
  { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
)
  .trim()
  .split("\n")
  .filter(Boolean)

let checked = 0
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
    let parser
    try {
      parser = String(S.parser(value))
    } catch {
      // Not every exported schema compiles a parser on its own; those cannot
      // strand a constructor either.
      continue
    }
    if (!parser.includes('["TAG"]===')) continue
    checked++
    const bug = strandedAfterGroup(parser)
    if (bug) failures.push({ file: relative, schemaName, ...bug })
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

console.log(`ok ${checked} tagged-union schemas, every constructor reachable`)
