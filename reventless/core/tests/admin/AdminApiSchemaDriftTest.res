// Structural guard for the three Platform_* admin queries. Every field of the
// record an entry is built from must reach both the SDL and the encoder, or be
// named below as a deliberate divergence. The tests beside this one pin values;
// this one pins the field SET — the thing that drifted silently when `chapter`
// and `externalSystem` were encoded for months with no SDL line to select them.

open JestGlobals
open Reventless.Plugin

// ── Field-name extraction ───────────────────────────────────────────────────

// The SDL blocks are one string per type, `type X {\n  field: T\n}`. A line with
// no colon is the header or the brace.
let sdlFieldNames = (~typeName: string, sdlTypes: array<string>): array<string> =>
  sdlTypes
  ->Array.find(block => block->String.startsWith(`type ${typeName} {`))
  ->Option.mapOr([], block =>
    block
    ->String.split("\n")
    ->Array.filterMap(line => {
      let trimmed = line->String.trim
      switch trimmed->String.indexOf(":") {
      | -1 => None
      | i => Some(trimmed->String.slice(~start=0, ~end=i))
      }
    })
  )

let jsonKeys = (j: JSON.t): array<string> =>
  switch j {
  | JSON.Object(d) => d->Dict.keysToArray
  | _ => []
  }

let schemaKeys = (schema: S.t<'a>): array<string> =>
  SchemaType.fromSuryObject(~typeName="", schema->S.castToUnknown)->Option.mapOr(
    [],
    Dict.keysToArray,
  )

// Nested types (`handledEvents`, `publishedEvents`) are encoded inline by their
// parent, so their wire keys are read off the first element rather than from an
// encoder of their own.
let firstOf = (j: JSON.t, key: string): JSON.t =>
  switch j {
  | JSON.Object(d) =>
    switch d->Dict.get(key) {
    | Some(JSON.Array(items)) => items->Array.get(0)->Option.getOr(JSON.Encode.null)
    | _ => JSON.Encode.null
    }
  | _ => JSON.Encode.null
  }

let missing = (names: array<string>, from: array<string>): array<string> =>
  names->Array.filter(n => !(from->Array.includes(n)))

// ── Fixtures: every optional field populated, so no key can go missing ───────

let fieldRef: fieldReference = {
  fieldName: "categoryId",
  entity: "Category",
  plugin: Some("Catalog"),
}

let cmd: commandDef = {
  name: "Add",
  schema: "{}",
  level: Collection,
  aggregateIdField: Some("productId"),
  mutationField: "Catalog_Product_Add",
  references: [fieldRef],
  allowedStates: Some(["Draft"]),
  targetState: Some("Active"),
  apiExposed: Some(true),
  requiredAccess: Some(["catalog.write"]),
  ownerField: Some("ownerId"),
}

let evt: eventDef = {name: "ProductAdded", schema: "{}", references: [fieldRef]}
let err: errorDef = {name: "ProductAlreadyExists", schema: "{}", references: []}

let writable: writableDef = {
  name: "Product",
  commands: [cmd],
  producedEventTypes: ["ProductAdded"],
  consumedEventTypes: [],
  linkedViews: ["Products"],
  consistencyRead: Some("Products"),
  events: [evt],
  errors: [err],
  chapter: Some("Catalogue"),
}

let queryable: queryableDef = {
  name: "Products",
  queryField: "Catalog_Products",
  schema: "{}",
  consumedEventTypes: ["ProductAdded"],
  linkedWriteSide: ["Product"],
  labelField: "displayName",
  searchableFields: ["displayName"],
  labelFieldSource: Some("annotation"),
  lifecycleField: Some("lifecycle"),
  ownerField: Some("ownerId"),
  retiredField: Some("archived"),
  retiredValues: Some(["Archived"]),
  namedWhenRetired: Some(true),
  visibility: None,
  chapter: Some("Catalogue"),
  singleQueryField: Some("Catalog_Product"),
  idField: Some("productId"),
  idFieldSource: Some("convention"),
  requiredAccess: Some(["catalog.read"]),
}

let automation: automationSliceDef = {
  name: "Restocker",
  consumedEventTypes: ["StockLow"],
  producedCommandTypes: ["Restock"],
  targetName: "Product",
  chapter: Some("Replenishment"),
}

let outbound: outboundTranslationSliceDef = {
  name: "ToShipper",
  consumedEventTypes: ["OrderPlaced"],
  inboundCommandTypes: ["Ship"],
  targetName: Some("Shipment"),
  externalSystem: Some("Shipper"),
  chapter: Some("Fulfilment"),
}

let inbound: inboundTranslationSliceDef = {
  name: "FromPsp",
  commandTypes: ["RecordPayment"],
  targetName: "Order",
  externalSystem: Some("Psp"),
  chapter: Some("Payments"),
}

let extension: extensionDef = {
  name: "Catalog.Products",
  delegateNames: ["Product"],
  eventTypes: ["ProductAdded"],
  commandTypes: ["Add"],
  handledEvents: Some([{name: "ProductAdded", toCommandTypes: ["Ordering.SyncNewProduct"]}]),
}

let extensionPoint: extensionPointDef = {
  name: "Catalog.Products",
  delegateNames: ["Product"],
  sourceEventTypes: ["Catalog.ProductAdded"],
  commandTypes: Some(["Add"]),
  publishedEvents: Some([
    {name: "Catalog.Products.ProductAdded", fromEventTypes: ["Catalog.ProductAdded"]},
  ]),
}

let storeDecl: requiredStoreDeclaration = {
  store: "catalog.images",
  component: "Product",
  field: "image",
  annotation: Some("images"),
}

let structure: pluginStructure = {
  readModels: [queryable],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [writable],
  automationSlices: [automation],
  outboundTranslationSlices: [outbound],
  inboundTranslationSlices: [inbound],
  extensions: [extension],
  extensionPoints: Some([extensionPoint]),
  requiredStores: Some(["catalog.images"]),
  requiredStoreDeclarations: Some([storeDecl]),
}

let panel: panelManifestEntry = {
  fragmentId: "Catalog.Products.list",
  title: "Products",
  description: "",
  positions: ["platform-summary"],
  requiredAccess: Some("admin"),
}

let menu: menuEntry = {
  label: "Products",
  icon: Some("box"),
  group: Some("Catalog"),
  sortOrder: 0,
}

let page: pageManifestEntry = {
  fragmentId: "Catalog.Products.list",
  title: "Products",
  menuEntry: menu,
  requiredAccess: Some("admin"),
}

let uiState: UiFragments.state = {
  pluginId: "Catalog",
  remoteEntryUrl: "https://cdn.example.test/catalog@1.0/remoteEntry.js",
  panels: [panel],
  pages: [page],
  registeredAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T00:00:00Z",
}

// ── Guards ──────────────────────────────────────────────────────────────────

type guard = {
  gqlType: string,
  sdlTypes: array<string>,
  recordFields: array<string>,
  wireFields: array<string>,
  /** Wire fields the encoder computes, with no counterpart on the record. */
  wireOnly: array<string>,
  /** Record fields deliberately kept off this query's wire. */
  recordOnly: array<string>,
}

let componentSdl = Platform_ComponentDefinitionsApi.sdlTypes
let structuresSdl = Platform_PluginStructuresApi.sdlTypes
let fragmentsSdl = Platform_UIFragmentsApi.sdlTypes

let encodedExtension = Platform_ComponentDefinitionsApi.encodeExtensionDef(extension)
let encodedExtensionPoint = Platform_PluginStructuresApi.encodeExtensionPointDef(extensionPoint)

let guards: array<guard> = [
  {
    gqlType: "Platform_FieldReference",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(fieldReferenceSchema),
    wireFields: jsonKeys(Platform_ComponentDefinitionsApi.encodeFieldReference(fieldRef)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_CommandDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(commandDefSchema),
    wireFields: jsonKeys(Platform_ComponentDefinitionsApi.encodeCommandDef(cmd)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_EventDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(eventDefSchema),
    wireFields: jsonKeys(Platform_ComponentDefinitionsApi.encodeEventDef(evt)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_ErrorDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(errorDefSchema),
    wireFields: jsonKeys(Platform_ComponentDefinitionsApi.encodeErrorDef(err)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_WriteSideDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(writableDefSchema),
    wireFields: jsonKeys(Platform_ComponentDefinitionsApi.encodeWritableDef(writable)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_ReadSideDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(queryableDefSchema),
    wireFields: jsonKeys(Platform_ComponentDefinitionsApi.encodeQueryableDef(queryable)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_AutomationSliceDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(automationSliceDefSchema),
    wireFields: jsonKeys(Platform_ComponentDefinitionsApi.encodeAutomationSliceDef(automation)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_OutboundTranslationSliceDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(outboundTranslationSliceDefSchema),
    wireFields: jsonKeys(
      Platform_ComponentDefinitionsApi.encodeOutboundTranslationSliceDef(outbound),
    ),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_InboundTranslationSliceDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(inboundTranslationSliceDefSchema),
    wireFields: jsonKeys(
      Platform_ComponentDefinitionsApi.encodeInboundTranslationSliceDef(inbound),
    ),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_ExtensionDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(extensionDefSchema),
    wireFields: jsonKeys(encodedExtension),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_HandledEventDef",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(handledEventDefSchema),
    wireFields: jsonKeys(encodedExtension->firstOf("handledEvents")),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_ComponentDefinitionEntry",
    sdlTypes: componentSdl,
    recordFields: schemaKeys(pluginStructureSchema),
    wireFields: jsonKeys(
      structure->Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
        ~pluginId="Catalog",
        _,
      ),
    ),
    // `pluginId` names the entry; `internalQueryables` is the complement of the
    // Internal filter, computed from the two lists beside it.
    wireOnly: ["pluginId", "internalQueryables"],
    // Producer-side and store fields belong to Platform_PluginStructures — the
    // deployed AutoUI has no use for either.
    recordOnly: ["extensionPoints", "requiredStores", "requiredStoreDeclarations"],
  },
  {
    gqlType: "Platform_PublishedEventDef",
    sdlTypes: structuresSdl,
    recordFields: schemaKeys(publishedEventDefSchema),
    wireFields: jsonKeys(encodedExtensionPoint->firstOf("publishedEvents")),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_ExtensionPointDef",
    sdlTypes: structuresSdl,
    recordFields: schemaKeys(extensionPointDefSchema),
    wireFields: jsonKeys(encodedExtensionPoint),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_RequiredStoreDeclaration",
    sdlTypes: structuresSdl,
    recordFields: schemaKeys(requiredStoreDeclarationSchema),
    wireFields: jsonKeys(Platform_PluginStructuresApi.encodeRequiredStoreDeclaration(storeDecl)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_PluginStructureEntry",
    sdlTypes: structuresSdl,
    recordFields: schemaKeys(pluginStructureSchema),
    wireFields: jsonKeys(
      Platform_PluginStructuresApi.encodePluginStructureEntry(~pluginId="Catalog", structure),
    ),
    wireOnly: ["pluginId"],
    // Nothing: this query is the unfiltered structure, by contract.
    recordOnly: [],
  },
  {
    gqlType: "Platform_UIPanel",
    sdlTypes: fragmentsSdl,
    recordFields: schemaKeys(panelManifestEntrySchema),
    wireFields: jsonKeys(Platform_UIFragmentsApi.encodePanel(panel)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_UIMenuEntry",
    sdlTypes: fragmentsSdl,
    recordFields: schemaKeys(menuEntrySchema),
    wireFields: jsonKeys(Platform_UIFragmentsApi.encodeMenuEntry(menu)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_UIPage",
    sdlTypes: fragmentsSdl,
    recordFields: schemaKeys(pageManifestEntrySchema),
    wireFields: jsonKeys(Platform_UIFragmentsApi.encodePage(page)),
    wireOnly: [],
    recordOnly: [],
  },
  {
    gqlType: "Platform_UIFragmentEntry",
    sdlTypes: fragmentsSdl,
    recordFields: schemaKeys(UiFragments.stateSchema),
    wireFields: jsonKeys(Platform_UIFragmentsApi.encodeUIFragmentEntry(uiState)),
    wireOnly: [],
    recordOnly: [],
  },
]

guards->Array.forEach(g => {
  let sdlFields = sdlFieldNames(~typeName=g.gqlType, g.sdlTypes)
  describe(g.gqlType, () => {
    // Without this, a renamed GraphQL type or an unreadable schema would make
    // every assertion below pass over two empty lists.
    testSync("the SDL block and the record schema are both readable", () => {
      expect(sdlFields->Array.length > 0)->toEqual(true)
      expect(g.recordFields->Array.length > 0)->toEqual(true)
    })

    testSync("every encoded field is selectable", () =>
      expect(missing(g.wireFields, sdlFields))->toEqual([])
    )

    testSync("every declared field is encoded", () =>
      expect(missing(sdlFields, g.wireFields))->toEqual([])
    )

    testSync("every record field reaches the wire", () =>
      expect(missing(g.recordFields, Array.concat(sdlFields, g.recordOnly)))->toEqual([])
    )

    testSync("the wire carries nothing the record and the divergences do not name", () =>
      expect(missing(sdlFields, Array.concat(g.recordFields, g.wireOnly)))->toEqual([])
    )
  })
})

// `encodePluginStructureEntry` serves two consumers: the query resolvers, which
// pass no `~derived`, and the baked manifest, which does. `derivedPages` is
// therefore absent from the SDL by design, and the guard above compares the
// resolver's call.
describe("derivedPages", () => {
  testSync("is emitted only for the baked manifest, and is not selectable", () => {
    let baked =
      structure->Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
        ~pluginId="Catalog",
        ~derived=["dashboard"],
        _,
      )
    expect(jsonKeys(baked)->Array.includes("derivedPages"))->toEqual(true)
    expect(
      sdlFieldNames(
        ~typeName="Platform_ComponentDefinitionEntry",
        componentSdl,
      )->Array.includes("derivedPages"),
    )->toEqual(false)
  })
})
