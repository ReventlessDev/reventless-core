// Drift guard for `Semantic.brandedStrings`.
//
// Membership and the `hasDerivableSchema` flag are both computable from the
// sources: a transparent-string semantic is a `semantic/` module whose `type t`
// is a bare `string`, and the flag is whether that module exposes a bare
// `let schema`. So this test recomputes both from the files rather than
// comparing two hand-written lists — two lists agree happily when both are
// wrong the same way, and the failure this guards against is a new module that
// nobody adds anywhere.
//
// The ppx keeps its own copy (`Util.branded_string_modules`) because OCaml
// cannot see through `type t = string` at syntax level. That copy is checked
// against the same computed truth here, so it cannot drift either.

open JestGlobals

let semanticDir = "src/semantic"
let ppxUtil = "../../packages/reventless-ppx/src/ppx/Util.ml"

let readFile = path => NodeFs.readFileSync(path)

let startsWithLine = (~source: string, ~prefix: string) =>
  source->String.split("\n")->Array.some(line => line->String.startsWith(prefix))

/** {moduleName, hasDerivableSchema} for every `type t = string` module on disk. */
let computedFromSources = () =>
  NodeFs.readdirSync(semanticDir, {withFileTypes: true})
  ->Array.filterMap(entry => {
    let name = entry->NodeFs.direntName
    if entry->NodeFs.isFile && name->String.endsWith(".res") {
      let source = readFile(semanticDir ++ "/" ++ name)
      if startsWithLine(~source, ~prefix="type t = string") {
        Some((
          name->String.slice(~start=0, ~end=String.length(name) - 4),
          startsWithLine(~source, ~prefix="let schema"),
        ))
      } else {
        None
      }
    } else {
      None
    }
  })
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))

/** The ppx's OCaml list, read back as pairs. Parsed rather than trusted so the
    test fails on a real divergence and not on formatting. */
let computedFromPpx = () => {
  let source = readFile(ppxUtil)
  switch source->String.split("let branded_string_modules = [") {
  | [_, rest] =>
    switch rest->String.split("]")->Array.get(0) {
    | Some(body) =>
      body
      ->String.replaceRegExp(/[\n\s]+/g, " ")
      ->String.split(";")
      ->Array.filterMap(entry => {
        let trimmed = entry->String.trim
        switch trimmed->String.split(",") {
        | [name, flag] =>
          Some((name->String.trim->String.replaceAll("\"", ""), flag->String.trim == "true"))
        | _ => None
        }
      })
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    | _ => []
    }
  | _ => []
  }
}

let fromRegistry = () =>
  Semantic.brandedStrings
  ->Array.map(b => (b.moduleName, b.hasDerivableSchema))
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))

describe("Semantic.brandedStrings", () => {
  // Without this, every comparison below passes vacuously on an empty read.
  testSync("the sources are actually readable from the test's working directory", () => {
    expect(NodeFs.existsSync(semanticDir))->toBe(true)
    expect(NodeFs.existsSync(ppxUtil))->toBe(true)
    expect(computedFromSources()->Array.length > 0)->toBe(true)
    expect(computedFromPpx()->Array.length > 0)->toBe(true)
  })

  testSync("lists exactly the modules whose `type t` is a bare string", () => {
    expect(fromRegistry()->Array.map(((m, _)) => m))->toEqual(
      computedFromSources()->Array.map(((m, _)) => m),
    )
  })

  testSync("flags exactly the modules exposing a name-derivable `let schema`", () => {
    expect(fromRegistry())->toEqual(computedFromSources())
  })

  testSync("the ppx's copy agrees with the same computed truth", () => {
    expect(computedFromPpx())->toEqual(computedFromSources())
  })

  testSync("every entry carries an id, and CalendarDate's is not derived from its name", () => {
    expect(Semantic.brandedStrings->Array.every(b => b.id != ""))->toBe(true)
    expect(
      Semantic.brandedStrings
      ->Array.find(b => b.moduleName == "CalendarDate")
      ->Option.map(b => b.id),
    )->toEqual(Some(Semantic.Id.date))
  })
})
