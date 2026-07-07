// Sync check for the generated D2 class block. Instead of parsing both blocks and
// comparing properties, it regenerates the inline block from the canonical
// `packages/doc/d2/reventless.d2` via the SAME generator the `pnpm sync:d2-styles`
// script uses, and asserts the committed `D2Classes.res` is byte-identical to that
// fresh output. If they differ, someone edited the canonical palette (or a
// tooling-only class) without re-running the generator. The canonical palette lives
// in THIS repo, so a missing file is a hard failure, not a skip.

open JestGlobals

let importMetaUrl: string = %raw(`import.meta.url`)

@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external dirname: string => string = "dirname"
@module("node:path") @variadic external joinPath: array<string> => string = "join"
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"

// The generator's pure core (plain ESM module under scripts/), shared with the
// `pnpm sync:d2-styles` writer so the check can never disagree with what it writes.
// `renderModule` builds the entire D2Classes.res content from canonical reventless.d2.
@module("../scripts/d2-classes-gen.mjs") external renderModule: string => string = "renderModule"

let testDir = dirname(fileURLToPath(importMetaUrl))
let canonicalPath = joinPath([testDir, "..", "..", "..", "packages", "doc", "d2", "reventless.d2"])
let committedPath = joinPath([testDir, "..", "src", "D2Classes.res"])

describe("D2Classes (generated from the canonical palette)", () => {
  testSync("exposes the class block + single-sourced shape colours", () =>
    expect((
      D2Classes.classes->String.startsWith("classes: {"),
      D2Classes.classes->String.includes(`"cross-plugin"`),
      D2Classes.extensionPointFill->String.startsWith("#"),
      D2Classes.extensionFill->String.startsWith("#"),
    ))->toEqual((true, true, true, true))
  )

  testSync("committed D2Classes.res equals a fresh regeneration (run `pnpm sync:d2-styles` on drift)", () =>
    expect(readFileSync(committedPath, "utf8"))->toEqual(
      renderModule(readFileSync(canonicalPath, "utf8")),
    )
  )
})
