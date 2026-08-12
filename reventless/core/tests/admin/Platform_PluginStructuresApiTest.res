// Asserts what makes `Platform_PluginStructures` different from
// `Platform_ComponentDefinitions`: nothing is filtered out, and the structure-level
// collections the AutoUI entry does not carry are present. A developer tool draws
// its graph from this response, so a component or a bridge missing here is a graph
// that silently disagrees with the source.

open JestGlobals
open Reventless.Plugin

let publicRm: queryableDef = {
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
  chapter: Some("Inventory"),
  singleQueryField: Some("Catalog_Product"),
  idField: Some("productId"),
  idFieldSource: Some("convention"),
  requiredAccess: None,
  ownerField: None,
}

// The component `Platform_ComponentDefinitions` drops and this query must keep.
let internalRm: queryableDef = {
  ...publicRm,
  name: "ProductAudit",
  queryField: "Catalog_ProductAudit",
  visibility: Some("Internal"),
}

let structure: pluginStructure = {
  readModels: [publicRm, internalRm],
  stateViewSlices: [internalRm],
  stateChangeSlices: [],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  extensionPoints: Some([
    {
      name: "Catalog.Products",
      delegateNames: ["onAdded"],
      sourceEventTypes: ["Catalog.ProductAdded"],
      commandTypes: None,
    },
  ]),
  requiredStores: Some(["Catalog.images"]),
  requiredStoreDeclarations: Some([
    {store: "Catalog.images", component: "Product", field: "image", annotation: Some("images")},
  ]),
}

let encoded = Platform_PluginStructuresApi.encodePluginStructureEntry(
  ~pluginId="Catalog",
  structure,
)
let json = encoded->JSON.stringify

let namesOf = (key): array<string> =>
  encoded
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get(key))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(v =>
    v->JSON.Decode.object->Option.flatMap(o => o->Dict.get("name"))->Option.flatMap(JSON.Decode.string)
  )

describe("Platform_PluginStructures entry", () => {
  testSync("carries the structure-level keys the AutoUI entry omits", () => {
    let dict = encoded->JSON.Decode.object->Option.getOr(Dict.make())
    let keys = dict->Dict.keysToArray->Array.toSorted(String.compare)
    expect(keys)->toEqual([
      "aggregates",
      "automationSlices",
      "extensionPoints",
      "extensions",
      "inboundTranslationSlices",
      "outboundTranslationSlices",
      "pluginId",
      "readModels",
      "requiredStoreDeclarations",
      "requiredStores",
      "stateChangeSlices",
      "stateViewSlices",
    ])
  })

  // The whole reason this query exists as a separate field.
  testSync("keeps Internal read models", () =>
    expect(namesOf("readModels"))->toEqual(["Products", "ProductAudit"])
  )

  testSync("keeps Internal state-view slices", () =>
    expect(namesOf("stateViewSlices"))->toEqual(["ProductAudit"])
  )

  testSync("carries visibility so a consumer can tell which are Internal", () =>
    expect(json->String.includes("\"visibility\":\"Internal\""))->toEqual(true)
  )

  testSync("encodes the chapter band", () =>
    expect(json->String.includes("\"chapter\":\"Inventory\""))->toEqual(true)
  )

  testSync("encodes extension points with their source event types", () =>
    expect(
      json->String.includes(
        "\"extensionPoints\":[{\"name\":\"Catalog.Products\",\"delegateNames\":[\"onAdded\"],\"sourceEventTypes\":[\"Catalog.ProductAdded\"],\"commandTypes\":null}]",
      ),
    )->toEqual(true)
  )

  // Both read-side queries share `encodeQueryableDef`, so this asserts the singular
  // name is not a ComponentDefinitions-only field: a developer tool building a detail
  // query reads it from here.
  testSync("encodes the singular query field beside the list one", () =>
    expect(json->String.includes("\"singleQueryField\":\"Catalog_Product\""))->toEqual(true)
  )

  testSync("encodes required stores with their provenance", () =>
    expect(json->String.includes("\"requiredStores\":[\"Catalog.images\"]"))->toEqual(true)
  )
})

// A structure persisted before these fields existed decodes as None, and null is the
// honest wire value — an empty list would claim the plugin has no extension points
// when the truth is that the deployment cannot say.
describe("absent optional collections", () => {
  let bare: pluginStructure = {
    ...structure,
    extensionPoints: None,
    requiredStores: None,
    requiredStoreDeclarations: None,
  }
  let bareJson =
    Platform_PluginStructuresApi.encodePluginStructureEntry(
      ~pluginId="Catalog",
      bare,
    )->JSON.stringify

  testSync("encodes absent extensionPoints as null", () =>
    expect(bareJson->String.includes("\"extensionPoints\":null"))->toEqual(true)
  )

  testSync("encodes absent requiredStores as null", () =>
    expect(bareJson->String.includes("\"requiredStores\":null"))->toEqual(true)
  )
})
