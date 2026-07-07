// Pins the two HAND-WRITTEN genType bridges (package root + src/ — see the header
// comments in each) against the GENERATED per-module `src/*.gen.ts` files: every
// `export type` genType emits must be re-exported by BOTH bridges under its
// `<Module>_`-prefixed name. Forgetting a bridge entry otherwise surfaces as a broken
// build in a *consumer* repo — this moves the failure to where the mistake is made.

open JestGlobals

let importMetaUrl: string = %raw(`import.meta.url`)

@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external dirname: string => string = "dirname"
@module("node:path") external joinPath: (string, string) => string = "join"
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"

let testDir = dirname(fileURLToPath(importMetaUrl))
let read = rel => readFileSync(joinPath(testDir, rel), "utf8")

// `export type <name>` at line start — genType's shape for every emitted type.
let exportedTypeNames = (genTs: string): array<string> => {
  let marker = "export type "
  genTs
  ->String.split("\n")
  ->Array.filterMap(line =>
    line->String.startsWith(marker)
      ? line
        ->String.slice(~start=marker->String.length, ~end=line->String.length)
        ->String.split(" ")
        ->Array.get(0)
      : None
  )
}

// (module prefix, generated file) — extend when a new @genType module is added.
let generatedModules = [("Protocol", "../src/Protocol.gen.ts"), ("GraphOps", "../src/GraphOps.gen.ts")]

let bridges = [
  ("package root", "../ReventlessVscodeProtocol.gen.ts"),
  ("src/", "../src/ReventlessVscodeProtocol.gen.ts"),
]

describe("genType bridge drift (hand-written bridges re-export every generated type)", () => {
  generatedModules->Array.forEach(((prefix, genFile)) => {
    let names = exportedTypeNames(read(genFile))

    testSync(`${prefix}: the generated file exports at least one type (regex sanity)`, () =>
      expect(names->Array.length > 0)->toBe(true)
    )

    bridges->Array.forEach(((bridgeLabel, bridgeFile)) => {
      let bridge = read(bridgeFile)
      testSync(`${prefix}: every generated type is re-exported by the ${bridgeLabel} bridge`, () => {
        let missing =
          names->Array.filter(n => !(bridge->String.includes(`${n} as ${prefix}_${n}`)))
        expect(missing)->toEqual([])
      })
    })
  })
})
