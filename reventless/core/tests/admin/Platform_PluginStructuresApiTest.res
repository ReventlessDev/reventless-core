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
  lifecycleField: None,
  visibility: None,
  chapter: Some("Inventory"),
  singleQueryField: Some("Catalog_Product"),
  idField: Some("productId"),
  idFieldSource: Some("convention"),
  requiredAccess: None,
  ownerField: None,
  retiredField: None,
  retiredValues: None,
  namedWhenRetired: None,
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
      publishedEvents: Some([
        {
          name: "Catalog.Products.ProductBecameAvailable",
          fromEventTypes: ["Catalog.ProductAdded"],
        },
      ]),
      acceptedCommands: Some([
        {name: "Catalog.Products.Reserve", toCommandTypes: ["Catalog.ReserveStock"]},
      ]),
    },
  ]),
  requiredStores: Some(["Catalog.images"]),
  requiredStoreDeclarations: Some([
    {store: "Catalog.images", component: "Product", field: "image", annotation: Some("images")},
  ]),
  requiredCapabilities: Some([{capability: "Geocoding", component: "GeocodeAddress"}]),
  traitDeclarations: None,
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
      "requiredCapabilities",
      "requiredStoreDeclarations",
      "requiredStores",
      "stateChangeSlices",
      "stateViewSlices",
      "traitDeclarations",
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
        "\"extensionPoints\":[{\"name\":\"Catalog.Products\",\"delegateNames\":[\"onAdded\"],\"sourceEventTypes\":[\"Catalog.ProductAdded\"],\"commandTypes\":null," ++
          "\"publishedEvents\":[{\"name\":\"Catalog.Products.ProductBecameAvailable\",\"fromEventTypes\":[\"Catalog.ProductAdded\"]}]," ++
          "\"acceptedCommands\":[{\"name\":\"Catalog.Products.Reserve\",\"toCommandTypes\":[\"Catalog.ReserveStock\"]}]}]",
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

  // No `field`: a capability a slice declares is not a field's need, which is why
  // it travels beside `requiredStores` rather than inside it.
  testSync("encodes required capabilities with their declaring component", () =>
    expect(
      json->String.includes(
        "\"requiredCapabilities\":[{\"capability\":\"Geocoding\",\"component\":\"GeocodeAddress\"}]",
      ),
    )->toEqual(true)
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
    requiredCapabilities: None,
    traitDeclarations: None,
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

  // The case the frozen corpus cannot reach: every fixture in it carries
  // `"outboundTranslationSlices":[]`, so no stored payload has an outbound slice
  // to be missing a field. A structure written before `consumedSources` existed
  // has no such key. `parseJsonTolerant` is what makes the absence survivable,
  // and it is the path the Plugin aggregate replays through.
  testSync("an outbound slice stored before consumedSources existed still replays", () =>
    expect(
      `{"name":"ToShipper","consumedEventTypes":[],"inboundCommandTypes":[]}`
      ->JSON.parseOrThrow
      ->Reventless.Message.parseJsonTolerant(outboundTranslationSliceDefSchema)
      ->(slice => slice.consumedSources),
    )->toEqual(None)
  )

  // Absent needs no healer: an omitted key IS the optional encoding, so strict
  // decode takes it. `parseJsonTolerant` above is for the fields a stale payload
  // is missing that are NOT optional.
  testSync("an omitted optional decodes as None on the strict path", () =>
    expect(
      `{"name":"ToShipper","consumedEventTypes":[],"inboundCommandTypes":[]}`
      ->JSON.parseOrThrow
      ->Reventless.Util_Sury.fromJson(outboundTranslationSliceDefSchema)
      ->(slice => slice.consumedSources),
    )->toEqual(None)
  )
})
