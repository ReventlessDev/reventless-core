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
}

let qbl: queryableDef = {
  name: "Products",
  queryField: "Catalog_Products",
  schema: "{}",
  consumedEventTypes: ["ProductAdded"],
  linkedWriteSide: ["Product"],
  labelField: "displayName",
  searchableFields: ["displayName"],
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

let encoded = ReventlessCore.Platform_UIDefinitionsApi.encodePluginStructureEntry(
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
})
