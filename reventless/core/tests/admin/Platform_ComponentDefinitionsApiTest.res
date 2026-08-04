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
  statusField: None,
  visibility: None,
  chapter: None,
}

let wbl: writableDef = {
  name: "Product",
  commands: [cmd],
  linkedViews: ["Products"],
  consistencyRead: None,
  producedEventTypes: ["ProductAdded"],
  consumedEventTypes: [],
  events: [{name: "ProductAdded", schema: "{}", references: []}],
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

  testSync("encodes None statusField as null", () =>
    expect(json->String.includes("\"statusField\":null"))->toEqual(true)
  )

  // Phase 6.3: write-side emitted-event field schemas.
  testSync("encodes writableDef events", () =>
    expect(json->String.includes("\"events\":[{\"name\":\"ProductAdded\""))->toEqual(true)
  )

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
    statusField: None,
    visibility: Some("Internal"),
    chapter: None,
  }
  let mixed: pluginStructure = {
    ...structure,
    readModels: [qbl, internalQbl],
    stateViewSlices: [internalQbl],
  }
  let mixedJson =
    Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId="Ordering", mixed)->JSON.stringify

  testSync("excludes an Internal queryableDef from the encoded read-side", () =>
    expect(mixedJson->String.includes("AvailableProducts"))->toEqual(false)
  )

  testSync("keeps a Public queryableDef", () =>
    expect(mixedJson->String.includes("\"name\":\"Products\""))->toEqual(true)
  )
})

describe("allowedStates + statusField populated", () => {
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
    statusField: Some("status"),
    visibility: None,
    chapter: None,
  }

  let wblWithStates: writableDef = {
    name: "Plugin",
    commands: [cmdWithStates],
    linkedViews: ["Plugin"],
    consistencyRead: None,
    producedEventTypes: [],
    consumedEventTypes: [],
    events: [],
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

  testSync("encodes populated statusField as the field name string", () =>
    expect(json->String.includes("\"statusField\":\"status\""))->toEqual(true)
  )
})
