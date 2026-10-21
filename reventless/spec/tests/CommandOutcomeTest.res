// Drift guard for `CommandOutcome.platformErrorCodes`. The PPX refuses a spec
// error named like one of them from its own OCaml copy, so the two lists must
// agree, or a new platform code would be reserved in one place only.

open JestGlobals

// Resolved from this module's own location: see SemanticBrandedStringsTest.
let here = NodePath.dirname(NodeUrl.fileURLToPath(NodeImportMeta.url))
let ppxCopy = here ++ "/../../../packages/reventless-ppx/src/ppx/PlatformErrorCodes.ml"

/** The PPX's list, parsed rather than trusted. */
let fromPpx = () =>
  switch NodeFs.readFileSync(ppxCopy)->String.split("let platform_error_codes = [") {
  | [_, rest] =>
    rest
    ->String.split("]")
    ->Array.get(0)
    ->Option.getOr("")
    ->String.split(";")
    ->Array.map(s => s->String.trim->String.replaceAll("\"", ""))
    ->Array.filter(s => s != "")
  | _ => []
  }

describe("CommandOutcome.platformErrorCodes", () => {
  testSync("the PPX's copy is readable and not empty", () => {
    expect(NodeFs.existsSync(ppxCopy))->toBe(true)
    expect(fromPpx()->Array.length > 0)->toBe(true)
  })

  testSync("the PPX reserves exactly the codes the platform emits", () => {
    expect(fromPpx())->toEqual(CommandOutcome.platformErrorCodes)
  })

  testSync("every code is distinct and spelled as its constructor", () => {
    let codes = CommandOutcome.platformErrorCodes
    expect(Set.fromArray(codes)->Set.size)->toBe(codes->Array.length)
    expect(CommandOutcome.code(Conflict))->toBe("Conflict")
    expect(CommandOutcome.isPlatformErrorCode("Forbidden"))->toBe(true)
    expect(CommandOutcome.isPlatformErrorCode("AlreadyBooked"))->toBe(false)
  })
})
