// Declaration-site tripwire for the schema-evolution rule documented on
// `Plugin.pluginStructure`.
//
// The sibling corpus test (PluginLifecycleCorpusTest) proves stored payloads still
// decode. It cannot catch a newly added required scalar, because since the healer
// learned to invent scalars they DO still decode — with a fabricated value and a
// runtime warning. A warning in a deployed log is roughly the signal that let the
// original two-day freeze go unnoticed, so the guard belongs here instead: in CI, at
// the moment the field is declared.
//
// Adding a `js_nullable` / array / enum / object field leaves this list untouched.
// Adding a bare required scalar changes it, and the diff is the conversation.

open JestGlobals

let moduleUrl: string = %raw(`import.meta.url`)

// The checked-in list. See the header of that file before changing it.
let golden = () =>
  NodeFs.readFileSync(
    NodePath.dirname(NodeUrl.fileURLToPath(moduleUrl)) ++ "/pluginDefinitionRequiredScalars.txt",
  )
  ->String.split("\n")
  ->Array.map(String.trim)
  ->Array.filter(line => line != "" && !(line->String.startsWith("#")))

describe("pluginDefinition's required scalar fields", () => {
  let actual = PluginDefinitionScalars.collect(Reventless.Plugin.pluginDefinitionSchema)
  let expected = golden()

  testSync("the golden list is populated (an empty read would pass vacuously)", () =>
    expect(expected->Array.length > 0)->toBe(true)
  )

  testSync("no bare required scalar has been added or removed", () => {
    let added = actual->Array.filter(f => !(expected->Array.includes(f)))
    let removed = expected->Array.filter(f => !(actual->Array.includes(f)))
    let describe = (label, fields) =>
      fields->Array.length == 0 ? "" : `\n  ${label}: ${fields->Array.join("\n            ")}`
    expect(describe("ADDED", added) ++ describe("REMOVED", removed))->toBe("")
  })
})
