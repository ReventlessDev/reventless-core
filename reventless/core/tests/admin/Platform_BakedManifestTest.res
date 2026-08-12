// The baked manifest is curation, so what matters is exactly which components
// survive an include-list — and, decisively, that an entry which includes
// everything is byte-identical to what the served query returns. Anything less
// and a shell reading the file is reading a second, quietly different contract.

open JestGlobals
open Reventless.Plugin

let queryable = (~name, ~visibility=?, ~ownerField=?, ()): queryableDef => {
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
  requiredAccess: None,
  ownerField,
}

let command = (~name, ~references=[], ~ownerField=?, ()): commandDef => {
  name,
  schema: "{}",
  level: Collection,
  aggregateIdField: None,
  mutationField: name->String.toLowerCase,
  references,
  allowedStates: None,
  targetState: None,
  apiExposed: Some(true),
  requiredAccess: None,
  ownerField,
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
    queryable(~name="Orders", ~ownerField="customerId", ()),
    queryable(~name="AvailableProducts", ~visibility="Internal", ()),
  ],
  stateChangeSlices: [
    writable(
      ~name="PlaceOrder",
      ~commands=[
        command(
          ~name="PlaceOrder",
          ~references=[{fieldName: "productIds", entity: "AvailableProducts", plugin: None}],
          ~ownerField="customerId",
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

  // A shell reading a baked file has no admin API to recover a reference target
  // from, so an Internal view a kept command points at has to survive the bake.
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

  // A shell reading a baked manifest has no admin API to ask instead, so a field
  // the curation step forgot to copy is a field that view can never learn about.
  // `curate` reuses the served encoder rather than writing its own, which is what
  // makes this hold — the assertion guards that property, not a second code path.
  testSync("a curated entry carries the owner field the served entry carries", () => {
    let entry =
      bake([{plugin: "Ordering", views: Some(["Orders"]), commands: Some(["PlaceOrder"])}])
      ->firstEntry
    let ownerOf = (key, name) =>
      entry
      ->JSON.Decode.object
      ->Option.flatMap(d => d->Dict.get(key))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(JSON.Decode.object)
      ->Array.find(d =>
        d->Dict.get("name")->Option.flatMap(JSON.Decode.string) == Some(name)
      )
      ->Option.flatMap(d => d->Dict.get("ownerField"))
      ->Option.flatMap(JSON.Decode.string)
    let commandOwner =
      entry
      ->JSON.Decode.object
      ->Option.flatMap(d => d->Dict.get("stateChangeSlices"))
      ->Option.flatMap(JSON.Decode.array)
      ->Option.getOr([])
      ->Array.filterMap(JSON.Decode.object)
      ->Array.flatMap(w =>
        w->Dict.get("commands")->Option.flatMap(JSON.Decode.array)->Option.getOr([])
      )
      ->Array.filterMap(JSON.Decode.object)
      ->Array.get(0)
      ->Option.flatMap(d => d->Dict.get("ownerField"))
      ->Option.flatMap(JSON.Decode.string)
    expect((ownerOf("stateViewSlices", "Orders"), commandOwner))->toEqual((
      Some("customerId"),
      Some("customerId"),
    ))
  })
})
