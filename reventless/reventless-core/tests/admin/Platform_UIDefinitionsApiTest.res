// Asserts the canonical JSON shape produced by encodePluginStructureEntry —
// shared by both the in-memory and AWS adapters. If this test changes, every
// console parsing the Platform_UIDefinitions response is affected.

open Jest
open Expect
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
}

let qbl: queryableDef = {
  name: "Products",
  queryField: "Catalog_Products",
  schema: "{}",
  consumedEventTypes: ["ProductAdded"],
  linkedWriteSide: ["Product"],
  labelField: "displayName",
  searchableFields: ["displayName"],
  statusField: None,
}

let wbl: writableDef = {
  name: "Product",
  commands: [cmd],
  linkedViews: ["Products"],
  consistencyRead: None,
  producedEventTypes: ["ProductAdded"],
  consumedEventTypes: [],
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
    },
  ],
  outboundTranslationSlices: [
    {
      name: "ToShipper",
      consumedEventTypes: ["OrderPlaced"],
      inboundCommandTypes: ["Ship"],
      targetName: None,
    },
  ],
  inboundTranslationSlices: [
    {name: "FromBilling", commandTypes: ["RecordPayment"], targetName: "Order"},
  ],
  extensions: [
    {
      name: "Catalog.Products.Watcher",
      delegateNames: ["onAdded"],
      eventTypes: ["ProductAdded"],
      commandTypes: [],
    },
  ],
}

let encoded = Platform_UIDefinitionsApi.encodePluginStructureEntry(
  ~pluginId="Catalog",
  structure,
)
let json = encoded->JSON.stringify

describe("encodePluginStructureEntry", () => {
  test("produces a JSON object with the expected top-level keys", () => {
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

  test("encodes pluginId", () =>
    expect(json->String.includes("\"pluginId\":\"Catalog\""))->toEqual(true)
  )

  test("encodes commandLevel as a literal string", () =>
    expect(json->String.includes("\"level\":\"Collection\""))->toEqual(true)
  )

  test("encodes None aggregateIdField as null", () =>
    expect(json->String.includes("\"aggregateIdField\":null"))->toEqual(true)
  )

  test("encodes None consistencyRead as null", () =>
    expect(json->String.includes("\"consistencyRead\":null"))->toEqual(true)
  )

  test("encodes Some plugin reference as its inner string", () =>
    expect(json->String.includes("\"plugin\":\"Catalog\""))->toEqual(true)
  )

  test("includes the queryableDef name", () =>
    expect(json->String.includes("\"name\":\"Products\""))->toEqual(true)
  )

  test("includes the automation slice name", () =>
    expect(json->String.includes("\"name\":\"Restocker\""))->toEqual(true)
  )

  test("encodes None allowedStates as null", () =>
    expect(json->String.includes("\"allowedStates\":null"))->toEqual(true)
  )

  test("encodes None statusField as null", () =>
    expect(json->String.includes("\"statusField\":null"))->toEqual(true)
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
  }

  let qblWithStatus: queryableDef = {
    name: "Plugin",
    queryField: "Platform_Plugins",
    schema: "{}",
    consumedEventTypes: [],
    linkedWriteSide: ["Plugin"],
    labelField: "name",
    searchableFields: ["name"],
    statusField: Some("status"),
  }

  let wblWithStates: writableDef = {
    name: "Plugin",
    commands: [cmdWithStates],
    linkedViews: ["Plugin"],
    consistencyRead: None,
    producedEventTypes: [],
    consumedEventTypes: [],
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
  }

  let json =
    structureWithStates
    ->Platform_UIDefinitionsApi.encodePluginStructureEntry(~pluginId="Platform", _)
    ->JSON.stringify

  test("encodes populated allowedStates as a JSON array", () =>
    expect(json->String.includes("\"allowedStates\":[\"Inactive\"]"))->toEqual(true)
  )

  test("encodes populated statusField as the field name string", () =>
    expect(json->String.includes("\"statusField\":\"status\""))->toEqual(true)
  )
})
