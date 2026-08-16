// Asserts the canonical JSON shape produced by encodePluginStructureEntry —
// shared by both the in-memory and AWS adapters. If this test changes, every
// console parsing the Platform_ComponentDefinitions response is affected.

open JestGlobals
open Reventless.Plugin

let cmd: commandDef = {
  name: "Add",
  schema: "{}",
  level: Collection,
  aggregateIdField: None,
  mutationField: "AddProduct",
  references: [
    {fieldName: "categoryId", entity: "Category", plugin: Some("Catalog")},
  ],
  allowedStates: None,
  targetState: None,
  apiExposed: Some(true),
  requiredAccess: None,
  ownerField: None,
}

let qbl: queryableDef = {
  name: "Products",
  queryField: "Catalog_Products",
  schema: "{}",
  consumedEventTypes: ["ProductAdded"],
  linkedWriteSide: ["Product"],
  labelField: "displayName",
  searchableFields: ["displayName"],
  labelFieldSource: Some("annotation"),
  lifecycleField: None,
  visibility: None,
  chapter: None,
  singleQueryField: Some("Catalog_Product"),
  idField: Some("productId"),
  idFieldSource: Some("convention"),
  requiredAccess: None,
  ownerField: None,
  retiredField: None,
  retiredValues: None,
}

let wbl: writableDef = {
  name: "Product",
  commands: [cmd],
  linkedViews: ["Products"],
  consistencyRead: None,
  producedEventTypes: ["ProductAdded"],
  consumedEventTypes: [],
  events: [{name: "ProductAdded", schema: "{}", references: []}],
  errors: [{name: "ProductAlreadyExists", schema: "{}", references: []}],
  chapter: None,
}

let structure: pluginStructure = {
  readModels: [qbl],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [wbl],
  automationSlices: [
    {
      name: "Restocker",
      consumedEventTypes: ["StockLow"],
      producedCommandTypes: ["Restock"],
      targetName: "Product",
      chapter: None,
    },
  ],
  outboundTranslationSlices: [
    {
      name: "ToShipper",
      consumedEventTypes: ["OrderPlaced"],
      inboundCommandTypes: ["Ship"],
      targetName: None,
      externalSystem: None,
      chapter: None,
    },
  ],
  inboundTranslationSlices: [
    {
      name: "FromBilling",
      commandTypes: ["RecordPayment"],
      targetName: "Order",
      externalSystem: None,
      chapter: None,
    },
  ],
  extensions: [
    {
      name: "Catalog.Products.Watcher",
      delegateNames: ["onAdded"],
      eventTypes: ["ProductAdded"],
      commandTypes: [],
    },
  ],
  extensionPoints: None,
  requiredStores: None,
  requiredStoreDeclarations: None,
}

let encoded = Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
  ~pluginId="Catalog",
  structure,
)
let json = encoded->JSON.stringify

describe("encodePluginStructureEntry", () => {
  testSync("produces a JSON object with the expected top-level keys", () => {
    let dict = encoded->JSON.Decode.object->Option.getOr(Dict.make())
    let keys = dict->Dict.keysToArray->Array.toSorted(String.compare)
    expect(keys)->toEqual([
      "aggregates",
      "automationSlices",
      "extensions",
      "inboundTranslationSlices",
      "internalQueryables",
      "outboundTranslationSlices",
      "pluginId",
      "readModels",
      "stateChangeSlices",
      "stateViewSlices",
    ])
  })

  testSync("encodes pluginId", () =>
    expect(json->String.includes("\"pluginId\":\"Catalog\""))->toEqual(true)
  )

  testSync("encodes commandLevel as a literal string", () =>
    expect(json->String.includes("\"level\":\"Collection\""))->toEqual(true)
  )

  testSync("encodes None aggregateIdField as null", () =>
    expect(json->String.includes("\"aggregateIdField\":null"))->toEqual(true)
  )

  testSync("encodes None consistencyRead as null", () =>
    expect(json->String.includes("\"consistencyRead\":null"))->toEqual(true)
  )

  testSync("encodes Some plugin reference as its inner string", () =>
    expect(json->String.includes("\"plugin\":\"Catalog\""))->toEqual(true)
  )

  testSync("includes the queryableDef name", () =>
    expect(json->String.includes("\"name\":\"Products\""))->toEqual(true)
  )

  testSync("includes the automation slice name", () =>
    expect(json->String.includes("\"name\":\"Restocker\""))->toEqual(true)
  )

  testSync("encodes None allowedStates as null", () =>
    expect(json->String.includes("\"allowedStates\":null"))->toEqual(true)
  )

  testSync("encodes None targetState as null (back-compat: resolver falls back to name-stem)", () =>
    expect(json->String.includes("\"targetState\":null"))->toEqual(true)
  )

  testSync("encodes the command's apiExposed flag (drives the event-graph API badge)", () =>
    expect(json->String.includes("\"apiExposed\":true"))->toEqual(true)
  )

  testSync("encodes None lifecycleField as null", () =>
    expect(json->String.includes("\"lifecycleField\":null"))->toEqual(true)
  )

  // Phase 6.3: write-side emitted-event field schemas.
  testSync("encodes writableDef events", () =>
    expect(json->String.includes("\"events\":[{\"name\":\"ProductAdded\""))->toEqual(true)
  )

  // The refusals a caller has to handle travel beside the facts it can observe.
  testSync("encodes writableDef errors", () =>
    expect(json->String.includes("\"errors\":[{\"name\":\"ProductAlreadyExists\""))->toEqual(true)
  )

  testSync("declares Platform_ErrorDef and the errors field in the shared write-side SDL", () => {
    let sdl = Platform_ComponentDefinitionsApi.sdlTypes->Array.join("\n")
    expect(sdl->String.includes("type Platform_ErrorDef"))->toEqual(true)
    expect(sdl->String.includes("errors: [Platform_ErrorDef!]!"))->toEqual(true)
  })

  // Translation-slice externalSystem: absent on the fixture above (both None), so it
  // must serialize as null — the "no external box" case. The leading field keeps the
  // two directions apart; `targetName` sits between them and is pinned here too.
  testSync("encodes None outbound externalSystem as null", () =>
    expect(
      json->String.includes(
        "\"inboundCommandTypes\":[\"Ship\"],\"targetName\":null,\"externalSystem\":null",
      ),
    )->toEqual(true)
  )

  testSync("encodes None inbound externalSystem as null", () =>
    expect(
      json->String.includes(
        "\"commandTypes\":[\"RecordPayment\"],\"targetName\":\"Order\",\"externalSystem\":null",
      ),
    )->toEqual(true)
  )
})

// A deployed-graph consumer draws the external-system boundary box off this field, so
// a slice whose spec sets `externalSystem = Some("X")` must surface "X" on the wire for
// both directions — the round-trip the plan pins.
describe("translation-slice externalSystem round-trip", () => {
  let externalStructure: pluginStructure = {
    ...structure,
    outboundTranslationSlices: [
      {
        name: "ToShipper",
        consumedEventTypes: ["OrderPlaced"],
        inboundCommandTypes: ["Ship"],
        targetName: None,
        externalSystem: Some("ShipperGateway"),
        chapter: None,
      },
    ],
    inboundTranslationSlices: [
      {
        name: "FromBilling",
        commandTypes: ["RecordPayment"],
        targetName: "Order",
        externalSystem: Some("BillingProvider"),
        chapter: None,
      },
    ],
  }
  let externalJson =
    Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
      ~pluginId="Catalog",
      externalStructure,
    )->JSON.stringify

  testSync("surfaces Some outbound externalSystem as its inner string", () =>
    expect(externalJson->String.includes("\"externalSystem\":\"ShipperGateway\""))->toEqual(true)
  )

  testSync("surfaces Some inbound externalSystem as its inner string", () =>
    expect(externalJson->String.includes("\"externalSystem\":\"BillingProvider\""))->toEqual(true)
  )
})

describe("visibility filtering (deployed AutoUI hides Internal)", () => {
  // Internal ReadModels / StateViewSlices are carried in pluginStructure for developer
  // tooling but must not surface in the UI definitions the deployed AutoUI builds its
  // menu / pages from — see Plugin_Structure.res / Visibility.res.
  let internalQbl: queryableDef = {
    name: "AvailableProducts",
    queryField: "Ordering_AvailableProducts",
    schema: "{}",
    consumedEventTypes: ["CatalogProductSynced"],
    linkedWriteSide: [],
    labelField: "name",
    searchableFields: ["name"],
    labelFieldSource: Some("convention"),
    lifecycleField: None,
    visibility: Some("Internal"),
    chapter: None,
    singleQueryField: Some("Ordering_AvailableProduct"),
    idField: Some("productId"),
    idFieldSource: Some("sole"),
    requiredAccess: None,
      ownerField: None,
      retiredField: None,
      retiredValues: None,
  }
  // A distinct name per source array: the complement has to be fed by both, and
  // reusing one def would hide a version that only walks `readModels`.
  let internalSlice: queryableDef = {
    ...internalQbl,
    name: "PendingShipments",
    queryField: "Ordering_PendingShipments",
  }
  let mixed: pluginStructure = {
    ...structure,
    readModels: [qbl, internalQbl],
    stateViewSlices: [internalSlice],
  }
  let mixedEntry =
    Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId="Ordering", mixed)

  // Names under one key of the encoded entry. `String.includes` over the whole
  // JSON can no longer answer this: an Internal view is legitimately present
  // under `internalQueryables`, so a whole-document search cannot tell "kept out
  // of the surfaces" from "dropped entirely" — which is the distinction the
  // feature is.
  let namesAt = (entry: JSON.t, key: string): array<string> =>
    entry
    ->JSON.Decode.object
    ->Option.flatMap(o => o->Dict.get(key))
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(c =>
      c->JSON.Decode.object->Option.flatMap(o => o->Dict.get("name"))->Option.flatMap(JSON.Decode.string)
    )

  testSync("excludes an Internal queryableDef from the encoded read-side", () => {
    expect(mixedEntry->namesAt("readModels"))->toEqual(["Products"])
    expect(mixedEntry->namesAt("stateViewSlices"))->toEqual([])
  })

  testSync("keeps a Public queryableDef", () =>
    expect(mixedEntry->namesAt("readModels")->Array.includes("Products"))->toEqual(true)
  )

  // Both directions, deliberately: a change that also leaked Internal views back
  // into the surface lists would pass a presence-only assertion.
  testSync("carries what the filter removed on internalQueryables", () =>
    expect(mixedEntry->namesAt("internalQueryables"))->toEqual([
      "AvailableProducts",
      "PendingShipments",
    ])
  )

  testSync("encodes internalQueryables as [] for an all-Public entry, not a missing key", () => {
    let entry = Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
      ~pluginId="Ordering",
      {...structure, readModels: [qbl], stateViewSlices: []},
    )
    expect(
      entry->JSON.Decode.object->Option.flatMap(o => o->Dict.get("internalQueryables")),
    )->toEqual(Some(JSON.Encode.array([])))
  })

  testSync("declares internalQueryables on the entry type in the SDL", () => {
    let sdl = Platform_ComponentDefinitionsApi.sdlTypes->Array.join("\n")
    expect(sdl->String.includes("internalQueryables: [Platform_ReadSideDef!]!"))->toEqual(true)
  })
})

describe("allowedStates + lifecycleField populated", () => {
  let cmdWithStates: commandDef = {
    name: "Activate",
    schema: "{}",
    level: Instance,
    aggregateIdField: Some("id"),
    mutationField: "Platform_Plugin_Activate",
    references: [],
    allowedStates: Some(["Inactive"]),
    targetState: Some("Active"),
    apiExposed: Some(true),
    requiredAccess: None,
      ownerField: None,
  }

  let qblWithStatus: queryableDef = {
    name: "Plugin",
    queryField: "Platform_Plugins",
    schema: "{}",
    consumedEventTypes: [],
    linkedWriteSide: ["Plugin"],
    labelField: "name",
    searchableFields: ["name"],
    labelFieldSource: Some("convention"),
    lifecycleField: Some("status"),
    visibility: None,
    chapter: None,
    singleQueryField: Some("Platform_Plugin"),
    idField: None,
    idFieldSource: None,
    requiredAccess: None,
      ownerField: None,
      retiredField: None,
      retiredValues: None,
  }

  let wblWithStates: writableDef = {
    name: "Plugin",
    commands: [cmdWithStates],
    linkedViews: ["Plugin"],
    consistencyRead: None,
    producedEventTypes: [],
    consumedEventTypes: [],
    events: [],
    errors: [],
    chapter: None,
  }

  let structureWithStates: pluginStructure = {
    readModels: [qblWithStatus],
    stateViewSlices: [],
    stateChangeSlices: [],
    aggregates: [wblWithStates],
    automationSlices: [],
    outboundTranslationSlices: [],
    inboundTranslationSlices: [],
    extensions: [],
    extensionPoints: None,
    requiredStores: None,
    requiredStoreDeclarations: None,
  }

  let json =
    structureWithStates
    ->Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId="Platform", _)
    ->JSON.stringify

  testSync("encodes populated allowedStates as a JSON array", () =>
    expect(json->String.includes("\"allowedStates\":[\"Inactive\"]"))->toEqual(true)
  )

  testSync("round-trips a declared targetState as the status string", () =>
    expect(json->String.includes("\"targetState\":\"Active\""))->toEqual(true)
  )

  testSync("encodes populated lifecycleField as the field name string", () =>
    expect(json->String.includes("\"lifecycleField\":\"status\""))->toEqual(true)
  )

  // "declares no errors" is an empty list, never null — the SDL types `errors` as
  // non-null, and a structure is re-derived on every build, so there is no third
  // "cannot say" state to encode.
  testSync("encodes a component with no declared errors as an empty array, not null", () => {
    expect(json->String.includes("\"errors\":[]"))->toEqual(true)
    expect(json->String.includes("\"errors\":null"))->toEqual(false)
  })
})

// The name exists so a consumer can stop re-implementing `Api_Naming.singularize`;
// it is only worth publishing if it reaches the caller intact, so assert the wire
// value and the SDL that types it, not just the record field.
describe("singleQueryField reaches the caller", () => {
  testSync("encodes the stated singular beside the list field", () => {
    expect(json->String.includes("\"queryField\":\"Catalog_Products\""))->toEqual(true)
    expect(json->String.includes("\"singleQueryField\":\"Catalog_Product\""))->toEqual(true)
  })

  // Nullable on purpose: a structure persisted before the field existed, or a
  // hand-rolled def that declines to state it, must decode rather than fail.
  testSync("encodes an unstated singular as null", () => {
    let unstated =
      {...structure, readModels: [{...qbl, singleQueryField: None}]}
      ->Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId="Catalog", _)
      ->JSON.stringify
    expect(unstated->String.includes("\"singleQueryField\":null"))->toEqual(true)
  })

  testSync("types it as a nullable String on the read-side SDL", () => {
    let sdl = Platform_ComponentDefinitionsApi.sdlTypes->Array.join("\n")
    expect(sdl->String.includes("singleQueryField: String\n"))->toEqual(true)
    expect(sdl->String.includes("singleQueryField: String!"))->toEqual(false)
  })
})

// The key and its rung travel together: a consumer ranking its own guess against
// this one needs both, so a version that carried the field and dropped the
// provenance would be worse than useless.
describe("idField / idFieldSource reach the caller", () => {
  testSync("encodes the key field and the rung that produced it", () => {
    expect(json->String.includes("\"idField\":\"productId\""))->toEqual(true)
    expect(json->String.includes("\"idFieldSource\":\"convention\""))->toEqual(true)
  })

  // A state whose key cannot be resolved (several `*Id` fields and no name match,
  // or none at all) has nothing to report — null, not an invented field name.
  testSync("encodes an unresolved key as null on both fields", () => {
    let unresolved =
      {...structure, readModels: [{...qbl, idField: None, idFieldSource: None}]}
      ->Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId="Catalog", _)
      ->JSON.stringify
    expect(unresolved->String.includes("\"idField\":null"))->toEqual(true)
    expect(unresolved->String.includes("\"idFieldSource\":null"))->toEqual(true)
  })

  testSync("types both as nullable Strings on the read-side SDL", () => {
    let sdl = Platform_ComponentDefinitionsApi.sdlTypes->Array.join("\n")
    expect(sdl->String.includes("idField: String\n"))->toEqual(true)
    expect(sdl->String.includes("idFieldSource: String\n"))->toEqual(true)
    expect(sdl->String.includes("idField: String!"))->toEqual(false)
  })
})
