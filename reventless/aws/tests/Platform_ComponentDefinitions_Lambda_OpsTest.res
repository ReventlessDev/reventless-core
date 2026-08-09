// Guards the read-path healing in Platform_ComponentDefinitions_Lambda_Ops.
//
// The handler serves a persisted plugin structure as raw JSON — it is never
// decoded through `pluginStructureSchema` — so a structure written before a
// required list field existed reaches the resolver without that key. Against the
// admin SDL's `[T!]!` the missing key resolves to null, GraphQL propagates the
// null up an unbroken non-null chain, and the entire query answers `data: null`.
// One plugin on an older structure therefore blackholes every other plugin.
//
// A plugin whose version never changes never re-runs the connect handshake, so it
// keeps its old structure indefinitely — the reason this is worth healing rather
// than waiting out.

open JestGlobals

let entry = (~filter, structure: JSON.t): option<dict<JSON.t>> =>
  Platform_ComponentDefinitions_Lambda_Ops.toEntryWith(
    ~filter,
    Dict.fromArray([("structure", structure)]),
    ~name="Ordering",
  )->Option.flatMap(JSON.Decode.object)

let members = (entry: dict<JSON.t>, collection: string): array<dict<JSON.t>> =>
  entry
  ->Dict.get(collection)
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(JSON.Decode.object)

// A state-change slice as persisted before `errors` (and before `references` on a
// command) existed: every other required list is present.
let preErrorsSlice = JSON.parseOrThrow(`{
  "name": "PlaceOrder",
  "commands": [{"name": "PlaceOrder", "schema": "{}", "level": "Collection", "mutationField": "placeOrder"}],
  "linkedViews": [],
  "producedEventTypes": ["OrderPlaced"],
  "consumedEventTypes": [],
  "events": []
}`)

let preErrorsStructure = Dict.fromArray([
  ("stateChangeSlices", JSON.Encode.array([preErrorsSlice])),
])->JSON.Encode.object

describe("toEntryWith heals a structure persisted before a required list existed", () => {
  testSync("fills the absent list on the component", () => {
    let slice =
      entry(~filter=false, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
    expect(slice->Option.flatMap(s => s->Dict.get("errors")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("fills the absent list one level down, on a command's references", () => {
    let command =
      entry(~filter=false, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
      ->Option.flatMap(s => s->Dict.get("commands"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.flatMap(Array.get(_, 0))
      ->Option.flatMap(JSON.Decode.object)
    expect(command->Option.flatMap(c => c->Dict.get("references")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("fills an absent collection, which is a non-null list of its own", () => {
    let e = entry(~filter=false, preErrorsStructure)
    expect(e->Option.flatMap(o => o->Dict.get("aggregates")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("leaves a present list untouched", () => {
    let slice =
      entry(~filter=false, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
    expect(slice->Option.flatMap(s => s->Dict.get("producedEventTypes")))->toEqual(
      Some(JSON.Encode.array([JSON.Encode.string("OrderPlaced")])),
    )
  })

  testSync("heals the filtered field too — both fields share the component types", () => {
    let slice =
      entry(~filter=true, preErrorsStructure)
      ->Option.map(members(_, "stateChangeSlices"))
      ->Option.flatMap(Array.get(_, 0))
    expect(slice->Option.flatMap(s => s->Dict.get("errors")))->toEqual(
      Some(JSON.Encode.array([])),
    )
  })

  testSync("still drops Internal read models when filtering", () => {
    let structure = Dict.fromArray([
      (
        "readModels",
        JSON.Encode.array([
          JSON.parseOrThrow(`{"name": "Orders", "visibility": "Internal"}`),
          JSON.parseOrThrow(`{"name": "Products"}`),
        ]),
      ),
    ])->JSON.Encode.object
    let names =
      entry(~filter=true, structure)
      ->Option.map(members(_, "readModels"))
      ->Option.getOr([])
      ->Array.filterMap(m => m->Dict.get("name")->Option.flatMap(JSON.Decode.string))
    expect(names)->toEqual(["Products"])
  })
})
