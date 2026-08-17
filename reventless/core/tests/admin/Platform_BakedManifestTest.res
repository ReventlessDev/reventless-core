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
  lifecycleField: None,
  visibility,
  chapter: None,
  singleQueryField: Some(`Ordering_${name}Single`),
  idField: Some("id"),
  idFieldSource: Some("convention"),
  requiredAccess: None,
  ownerField,
  retiredField: None,
  retiredValues: None,
  namedWhenRetired: None,
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

// Every case below varies one include-list and means "everything" by the rest,
// which is exactly what an omitted labelled argument says.
let sel = (~plugin, ~views=?, ~commands=?, ~derived=?): Platform_BakedManifest.selection => {
  plugin,
  views,
  commands,
  derived,
}

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
      bake([sel(~plugin="Ordering", ~views=["Orders"], ~commands=["PlaceOrder"])])->firstEntry
    expect((entry->names("stateViewSlices"), entry->names("readModels")))->toEqual((["Orders"], []))
  })

  testSync("drops a write side whose commands were all excluded", () => {
    let entry = bake([sel(~plugin="Ordering", ~views=[], ~commands=["PlaceOrder"])])->firstEntry
    expect(entry->names("stateChangeSlices"))->toEqual(["PlaceOrder"])
  })

  testSync("unset views and commands include every public component", () => {
    let entry = bake([sel(~plugin="Ordering")])->firstEntry
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
      bake([sel(~plugin="Ordering", ~views=["Orders"], ~commands=["PlaceOrder"])])
      ->firstEntry
    expect(entry->names("internalQueryables"))->toEqual(["AvailableProducts"])
  })

  testSync("omits an Internal view no included command references", () => {
    let entry =
      bake([sel(~plugin="Ordering", ~views=["Orders"], ~commands=["ImportOrders"])])
      ->firstEntry
    expect(entry->names("internalQueryables"))->toEqual([])
  })

  // The pages a shell builds across a plugin's views do not exist on this side,
  // so what the bake can do about them is state which kinds an audience gets and
  // carry that to the shell. Absent and empty therefore have to stay two
  // different answers all the way out to the JSON, which is what these three
  // cases pin: nothing said ⇒ no key ⇒ every kind, and `[]` ⇒ a key ⇒ none.
  let derivedOf = (entry: JSON.t) =>
    entry
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("derivedPages"))
    ->Option.map(v => v->JSON.Decode.array->Option.getOr([])->Array.filterMap(JSON.Decode.string))

  testSync("unset derived says nothing, leaving every kind to the shell", () =>
    expect(bake([sel(~plugin="Ordering")])->firstEntry->derivedOf)->toEqual(None)
  )

  testSync("an empty derived list is carried, and is not the same as unset", () =>
    expect(bake([sel(~plugin="Ordering", ~derived=[])])->firstEntry->derivedOf)->toEqual(Some([]))
  )

  testSync("carries exactly the derived kinds named", () =>
    expect(
      bake([sel(~plugin="Ordering", ~derived=["lifecycles", "canvas"])])->firstEntry->derivedOf,
    )->toEqual(Some(["lifecycles", "canvas"]))
  )

  // Against the vocabulary, never against this plugin: a kind that generates no
  // page for these schemas is a fact about the plugin, not a typo, and a shop
  // that names `lifecycles` before its views carry a status is early, not wrong.
  testSync("fails naming a derived kind outside the vocabulary", () =>
    expect(bake([sel(~plugin="Ordering", ~derived=["dashboards"])]))->toEqual(
      Error(Platform_BakedManifest.UnknownDerived({plugin: "Ordering", kind: "dashboards"})),
    )
  )

  testSync("accepts a kind this plugin generates no page for", () =>
    expect(
      bake([sel(~plugin="Ordering", ~derived=["scheduler"])])->firstEntry->derivedOf,
    )->toEqual(Some(["scheduler"]))
  )

  testSync("an Internal view is never selectable as a view", () =>
    expect(bake([sel(~plugin="Ordering", ~views=["AvailableProducts"])]))->toEqual(
      Error(Platform_BakedManifest.UnknownView({plugin: "Ordering", view: "AvailableProducts"})),
    )
  )

  testSync("fails naming an unknown plugin", () =>
    expect(bake([sel(~plugin="Shipping")]))->toEqual(
      Error(Platform_BakedManifest.UnknownPlugin("Shipping")),
    )
  )

  testSync("fails naming an unknown command", () =>
    expect(bake([sel(~plugin="Ordering", ~commands=["CancelOrder"])]))->toEqual(
      Error(Platform_BakedManifest.UnknownCommand({plugin: "Ordering", command: "CancelOrder"})),
    )
  )

  // The anti-drift assertion: include everything and the baked entry IS the
  // served entry. Any future divergence in the encoder shows up here first.
  testSync("an all-inclusive bake is byte-identical to the served entry", () => {
    let baked = bake([sel(~plugin="Ordering")])->firstEntry
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
          sel(~plugin="Catalog", ~views=[], ~commands=[]),
          sel(~plugin="Ordering", ~views=[], ~commands=[]),
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
      bake([sel(~plugin="Ordering", ~views=["Orders"], ~commands=["PlaceOrder"])])
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
