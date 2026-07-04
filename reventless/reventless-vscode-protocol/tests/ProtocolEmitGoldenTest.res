// Freezes the exact NDJSON *bytes* the CLI emits for every `streamEvent` variant.
// The round-trip test proves each variant decodes; this proves the wire bytes don't
// drift — a serialization change that still round-trips (field reorder, key rename,
// number formatting) would break consumers pinned to specific bytes, and shows up
// here as a golden diff instead of silently.
//
// The golden file (`fixtures/streamEvents.golden.ndjson`) is a *published* artifact
// (outside the npmignored `tests/`), so an external decoder — the VS Code extension
// or any other tool — can replay it against its own parser in its own CI.
//
// Regenerate after an intentional wire change:  UPDATE_GOLDEN=1 pnpm test
// then review the fixture diff and commit it.

open JestGlobals

module P = Protocol

let importMetaUrl: string = %raw(`import.meta.url`)

@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external dirname: string => string = "dirname"
@module("node:path") external joinPath: (string, string) => string = "join"
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@val @scope("process") external env: Dict.t<string> = "env"

let testDir = dirname(fileURLToPath(importMetaUrl))
let goldenPath = joinPath(testDir, "../fixtures/streamEvents.golden.ndjson")

let emitted = ProtocolSamples.cases->Array.map(((_, e)) => P.toJsonLine(e))

// Golden-update affordance: rewrite the fixture from the current emit output. Runs
// at import time (before the assertions), so a regenerating run always passes.
switch env->Dict.get("UPDATE_GOLDEN") {
| Some(_) => writeFileSync(goldenPath, emitted->Array.join("\n") ++ "\n")
| None => ()
}

let goldenLines =
  readFileSync(goldenPath, "utf8")->String.trimEnd->String.split("\n")

describe("Protocol emit golden (frozen NDJSON wire bytes)", () => {
  testSync("fixture line count matches the sample set", () =>
    expect(goldenLines->Array.length)->toBe(ProtocolSamples.cases->Array.length)
  )

  ProtocolSamples.cases->Array.forEachWithIndex(((name, e), i) => {
    testSync(`${name}: emits the exact golden bytes`, () =>
      expect(P.toJsonLine(e))->toBe(goldenLines->Array.getUnsafe(i))
    )
    testSync(`${name}: golden line decodes back to the variant`, () =>
      expect(P.parseStreamEvent(goldenLines->Array.getUnsafe(i)))->toEqual(Some(e))
    )
  })
})
