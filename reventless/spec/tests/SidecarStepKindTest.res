// The step kinds the PPX writes into a scenario sidecar and the kinds
// `SidecarStepKind` reads are one list.
//
// The PPX writes every kind through `StepKind.word`, one arm per kind, each
// writing its constructor's name. This reads those arms from the OCaml source,
// so a kind added on one side and not the other fails here, in the same run as
// the rest of the tests, without a PPX binary.

open JestGlobals

// Resolved from this module's own location: the runner's working directory is
// the repo root for a whole-workspace run and the package for a single one.
let here = NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url))
let ppxStepKind = here ++ "/../../../packages/reventless-ppx/src/ppx/StepKind.ml"

/** `(constructor, word)` for every arm of `let word = function`. */
let writtenByPpx = () => {
  let source = NodeFs.readFileSync(ppxStepKind)
  let body = switch source->String.split("let word = function")->Array.get(1) {
  | Some(rest) => rest
  | None => ""
  }
  body
  ->String.split("\n")
  ->Array.filterMap(line =>
    switch line->String.trim->String.match(/^\|\s*([A-Z]\w*)\s*->\s*"([^"]*)"$/) {
    | Some([_, Some(constructor), Some(word)]) => Some((constructor, word))
    | _ => None
    }
  )
}

describe("SidecarStepKind", () => {
  testSync("the PPX's source lists its step kinds where this test reads them", () =>
    expect(Array.length(writtenByPpx()) > 20)->toBe(true)
  )

  testSync("the PPX writes each kind as its constructor's name", () =>
    expect(writtenByPpx()->Array.filter(((constructor, word)) => constructor != word))->toEqual([])
  )

  testSync("every word the PPX writes reads as a kind this build knows", () =>
    expect(
      writtenByPpx()
      ->Array.map(((_, word)) => word)
      ->Array.filter(
        word =>
          switch SidecarStepKind.ofString(word) {
          | OtherSidecarStep(_) => true
          | _ => false
          },
      ),
    )->toEqual([])
  )

  testSync("every kind this build knows is one the PPX writes, in the same order", () =>
    expect(SidecarStepKind.known->Array.map(SidecarStepKind.toString))->toEqual(
      writtenByPpx()->Array.map(((_, word)) => word),
    )
  )

  testSync("a word this build does not know is kept and prints back", () => {
    let kind = SidecarStepKind.ofString("ThenSomethingNew")
    expect(kind)->toEqual(SidecarStepKind.OtherSidecarStep("ThenSomethingNew"))
    expect(SidecarStepKind.toString(kind))->toBe("ThenSomethingNew")
  })

  testSync(
    "an older PPX's lower-case word is read as unknown, and the reason names the PPX",
    () => {
      expect(SidecarStepKind.ofString("event"))->toEqual(SidecarStepKind.OtherSidecarStep("event"))
      expect(
        SidecarStepKind.unknownWordReason("event")->String.includes("older reventless-ppx"),
      )->toBe(true)
      expect(
        SidecarStepKind.unknownWordReason("ThenSomethingNew")->String.includes(
          "newer reventless-ppx",
        ),
      )->toBe(true)
    },
  )
})
