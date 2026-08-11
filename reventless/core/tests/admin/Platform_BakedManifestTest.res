// The baked manifest is curation, so what matters is exactly which components
// survive an include-list — and, decisively, that an entry which includes
// everything is byte-identical to what the served query returns. Anything less
// and a shell reading the file is reading a second, quietly different contract.

open JestGlobals
open Reventless.Plugin

let queryable = (~name, ~visibility=?, ()): queryableDef => {
  name,
  queryField: `Ordering_${name}`,
  schema: "{}",
  consumedEventTypes: [],
  linkedWriteSide: [],
  labelField: "displayName",
  searchableFields: ["displayName"],
  labelFieldSource: None,
  statusField: None,
  visibility,
  chapter: None,
  singleQueryField: Some(`Ordering_${name}Single`),
  idField: Some("id"),
  idFieldSource: Some("convention"),
}

let command = (~name, ~references=[], ()): commandDef => {
  name,
  schema: "{}",
  level: Collection,
  aggregateIdField: None,
  mutationField: name->String.toLowerCase,
  references,
  allowedStates: None,
  targetState: None,
  apiExposed: Some(true),
}

let writable = (~name, ~commands): writableDef => {
  name,
  commands,
  linkedViews: [],
  consistencyRead: None,
  producedEventTypes: [],
  consumedEventTypes: [],
  events: [],
  errors: [],
  chapter: None,
}

// Mirrors the hybrid example's shape: a public order list, an Internal
// denormalised product mirror a command @refs, one end-user command and one
// operator command.
let structure: pluginStructure = {
  readModels: [queryable(~name="Customers", ())],
  stateViewSlices: [
    queryable(~name="Orders", ()),
    queryable(~name="AvailableProducts", ~visibility="Internal", ()),
  ],
  stateChangeSlices: [
    writable(
      ~name="PlaceOrder",
      ~commands=[
        command(
          ~name="PlaceOrder",
          ~references=[{fieldName: "productIds", entity: "AvailableProducts", plugin: None}],
          (),
        ),
      ],
    ),
    writable(~name="ImportOrders", ~commands=[command(~name="ImportOrders", ())]),
  ],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  extensionPoints: None,
  requiredStores: None,
  requiredStoreDeclarations: None,
}

let structures = [("Ordering@1.0.0", structure)]

let bake = selections =>
  Platform_BakedManifest.curate(~structures, ~selections)

let entries = (json: JSON.t) => json->JSON.Decode.array->Option.getOr([])

let names = (entry: JSON.t, field: string) =>
  entry
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(field))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(v =>
    v->JSON.Decode.object->Option.flatMap(d => d->Dict.get("name"))->Option.flatMap(JSON.Decode.string)
  )

let firstEntry = (r: result<JSON.t, Platform_BakedManifest.error>) =>
  switch r {
  | Ok(json) => json->entries->Array.getUnsafe(0)
  | Error(e) => JsError.throwWithMessage(Platform_BakedManifest.describe(e))
  }

describe("curate", () => {
  testSync("selects exactly the named components", () => {
    let entry =
      bake([{plugin: "Ordering", views: Some(["Orders"]), commands: Some(["PlaceOrder"])}])
      ->firstEntry
    expect((entry->names("stateViewSlices"), entry->names("readModels")))->toEqual((["Orders"], []))
  })

  testSync("drops a write side whose commands were all excluded", () => {
    let entry =
      bake([{plugin: "Ordering", views: Some([]), commands: Some(["PlaceOrder"])}])->firstEntry
    expect(entry->names("stateChangeSlices"))->toEqual(["PlaceOrder"])
  })

  testSync("unset views and commands include every public component", () => {
    let entry = bake([{plugin: "Ordering", views: None, commands: None}])->firstEntry
    expect((
      entry->names("readModels"),
      entry->names("stateViewSlices"),
      entry->names("stateChangeSlices"),
    ))->toEqual((["Customers"], ["Orders"], ["PlaceOrder", "ImportOrders"]))
  })

  // The point of E13's manifest field, carried into the bake: a shell reading a
  // baked file has no admin API to recover a reference target from.
  testSync("carries an Internal view referenced by an included command", () => {
    let entry =
      bake([{plugin: "Ordering", views: Some(["Orders"]), commands: Some(["PlaceOrder"])}])
      ->firstEntry
    expect(entry->names("internalQueryables"))->toEqual(["AvailableProducts"])
  })

  testSync("omits an Internal view no included command references", () => {
    let entry =
      bake([{plugin: "Ordering", views: Some(["Orders"]), commands: Some(["ImportOrders"])}])
      ->firstEntry
    expect(entry->names("internalQueryables"))->toEqual([])
  })

  testSync("an Internal view is never selectable as a view", () =>
    expect(
      bake([{plugin: "Ordering", views: Some(["AvailableProducts"]), commands: None}]),
    )->toEqual(
      Error(Platform_BakedManifest.UnknownView({plugin: "Ordering", view: "AvailableProducts"})),
    )
  )

  testSync("fails naming an unknown plugin", () =>
    expect(bake([{plugin: "Shipping", views: None, commands: None}]))->toEqual(
      Error(Platform_BakedManifest.UnknownPlugin("Shipping")),
    )
  )

  testSync("fails naming an unknown command", () =>
    expect(bake([{plugin: "Ordering", views: None, commands: Some(["CancelOrder"])}]))->toEqual(
      Error(Platform_BakedManifest.UnknownCommand({plugin: "Ordering", command: "CancelOrder"})),
    )
  )

  // The anti-drift assertion: include everything and the baked entry IS the
  // served entry. Any future divergence in the encoder shows up here first.
  testSync("an all-inclusive bake is byte-identical to the served entry", () => {
    let baked = bake([{plugin: "Ordering", views: None, commands: None}])->firstEntry
    let served = Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
      ~pluginId="Ordering@1.0.0",
      structure,
    )
    expect(baked->JSON.stringify)->toEqual(served->JSON.stringify)
  })

  testSync("one entry per selection, in declaration order", () => {
    let json =
      Platform_BakedManifest.curate(
        ~structures=[("Ordering@1.0.0", structure), ("Catalog@1.0.0", structure)],
        ~selections=[
          {plugin: "Catalog", views: Some([]), commands: Some([])},
          {plugin: "Ordering", views: Some([]), commands: Some([])},
        ],
      )
    let ids =
      switch json {
      | Ok(j) =>
        j
        ->entries
        ->Array.filterMap(e =>
          e
          ->JSON.Decode.object
          ->Option.flatMap(d => d->Dict.get("pluginId"))
          ->Option.flatMap(JSON.Decode.string)
        )
      | Error(_) => []
      }
    expect(ids)->toEqual(["Catalog", "Ordering"])
  })
})
