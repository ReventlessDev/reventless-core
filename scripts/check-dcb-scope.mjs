#!/usr/bin/env node
// Fail when a plugin's DCB consistency boundary cannot derive its tag scope.
//
// `DcbScopeInference` derives each slice's partition from the slice graph, and
// `DcbTag.deriveEffectiveScope` threads the result all-or-nothing: one slice whose
// partition does not resolve discards the derivation for every slice beside it and
// falls back to the hand-written `@crossPartition` annotations. Since reference
// reads are inferred rather than annotated, that fallback is usually empty, and a
// slice that validates another entity by id then reads only its own partition —
// deciding against a history it cannot see and rejecting a command whose facts are
// in the log. No exception, no failed write, no log line anyone reads at 09:00.
//
// Two properties make this worth a check rather than a test:
//
// - It is a property of the SET, so no per-slice test can hold it. Every slice in
//   a degraded boundary passes its own suite; the harness derives scope per slice,
//   where a partition always resolves. The one composed suite covers the plugins
//   it composes, and this covers every plugin in the repository.
//
// - The scope it prints is a contract. Which keys are cross-partition decides
//   which reads fan out and which tags are written to a GSI, so a change to the
//   derived scope changes the runtime for slices nobody edited. The golden makes
//   that a reviewable diff rather than a surprise in production.
//
// Plain .mjs because it is untyped reflection: a plugin is found by path and its
// `dcbSliceSchemas` is a value shaped by that plugin, not by anything this
// repository can name.
//
// Usage:
//   pnpm run check:dcb-scope           # fail on an ambiguity or golden drift
//   pnpm run check:dcb-scope:update    # rewrite the goldens

import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const UPDATE = process.argv.includes("--update")

const DcbTag = await import(
  path.join(ROOT, "reventless/spec/src/components/DcbTag.res.mjs")
)
const Inference = await import(
  path.join(ROOT, "reventless/spec/src/components/DcbScopeInference.res.mjs")
)

// A plugin is a directory holding a compiled `src/Plugin.res.mjs`; it is part of
// a DCB boundary only if the generator emitted `dcbSliceSchemas`, which it does
// exactly when the plugin has StateChangeSlices.
const plugins = (exampleDir) =>
  readdirSync(exampleDir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith("."))
    .map((e) => ({ name: e.name, entry: path.join(exampleDir, e.name, "src/Plugin.res.mjs") }))
    .filter((p) => existsSync(p.entry))

const examples = readdirSync(path.join(ROOT, "examples"), { withFileTypes: true })
  .filter((e) => e.isDirectory() && !e.name.startsWith("."))
  .map((e) => e.name)
  .sort()

let failures = 0
let drift = 0

for (const example of examples) {
  const exampleDir = path.join(ROOT, "examples", example)
  const report = {}

  for (const { name, entry } of plugins(exampleDir)) {
    const mod = await import(entry)
    const slices = mod.dcbSliceSchemas
    if (!slices || slices.length === 0) continue

    const shapes = slices.map((s) =>
      DcbTag.sliceShapeFromSchemas(
        s.name,
        s.commandSchema,
        s.consumedEventSchema,
        s.eventSchema,
      ),
    )
    const inferred = Inference.infer(shapes)
    const effective = DcbTag.deriveEffectiveScope(slices)

    for (const [slice, reason] of inferred.ambiguities) {
      failures++
      console.error(`✗ ${example}/${name}: ${slice} — ${reason}`)
    }
    if (effective.droppedCrossPartitionTagKeys.length > 0) {
      console.error(
        `  → the boundary lost cross-partition reads of [${effective.droppedCrossPartitionTagKeys.join(", ")}];` +
          ` slices referencing another entity by these keys will reject valid commands`,
      )
    }

    // The golden records what the boundary resolved to, not merely that it did:
    // each slice's partition, and the keys read across partitions. Both change the
    // query a slice issues, so both are worth a reviewer's eye.
    report[name] = {
      partitionBySlice: Object.fromEntries(
        Object.entries(inferred.partitionBySlice).sort(([a], [b]) => a.localeCompare(b)),
      ),
      crossPartitionTagKeys: effective.crossPartitionTagKeys,
    }
  }

  if (Object.keys(report).length === 0) continue

  const goldenPath = path.join(exampleDir, "schema", "dcb-scope.json")
  const actual = JSON.stringify(report, null, 2) + "\n"
  if (UPDATE) {
    mkdirSync(path.dirname(goldenPath), { recursive: true })
    const existed = existsSync(goldenPath)
    writeFileSync(goldenPath, actual)
    console.log(`${existed ? "updated" : "wrote"} ${example}/schema/dcb-scope.json`)
  } else if (!existsSync(goldenPath)) {
    drift++
    console.error(`✗ missing golden ${example}/schema/dcb-scope.json — run pnpm run check:dcb-scope:update`)
  } else if (readFileSync(goldenPath, "utf8") !== actual) {
    drift++
    console.error(`✗ drift in ${example}/schema/dcb-scope.json`)
    console.error(`  expected:\n${readFileSync(goldenPath, "utf8")}`)
    console.error(`  actual:\n${actual}`)
  } else {
    console.log(`✓ ${example} — ${Object.keys(report).length} boundary(ies) resolved`)
  }
}

if (failures > 0 || drift > 0) {
  console.error(
    `\n${failures} unresolved slice(s), ${drift} golden drift(s). ` +
      `An unresolved partition is usually a consumed arm declaring the id its slice is already partitioned by — remove the field.`,
  )
  process.exit(1)
}
