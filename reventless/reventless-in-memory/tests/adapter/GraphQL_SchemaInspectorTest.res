// Tests for GraphQL_SchemaInspector — verifies schema introspection at granular,
// plugin-fragment, and platform levels.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

let _ = TestRunner.setup()

// ── Test schemas ────────────────────────────────────────────────────────────

let stringSchema = S.string
let taggedSchema = Reventless.DcbTag.string
let numberSchema = S.float
let boolSchema = S.bool

@schema
type testState = {
  id: @s.matches(Reventless.DcbTag.string) string,
  name: string,
  price: float,
  active: bool,
}

@schema
type svState = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  name: string,
  price: float,
}

@schema
type addCommand = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  name: string,
}

@schema
type unionCommand =
  | Create({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | Rename({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})

// State schemas exercising structural annotations (Phase 1 server capability)
@schema
type plainState = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  name: string,
}

@schema
type indexedState = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  ownerId: string,
  status: string,
  name: string,
}
let indexedStateSchemaWithAnnotations = indexedStateSchema->S.Metadata.set(
  ~id=Reventless.StateAnnotations.stateAnnotationsId,
  {
    ids: ["productId"],
    compositeIds: [],
    subIds: [],
    compositeSubIds: [],
    indexes: [("ownerId", "byOwner")],
    hidden: [],
    summary: [],
    drillTargets: [],
    drillTargetKeys: [],
    collapsed: [],
    scan: [],
    scanSort: [],
    status: None,
    visibility: None,
  },
)

@schema
type orderedState = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  createdAt: string,
  name: string,
}
let orderedStateSchemaWithAnnotations = orderedStateSchema->S.Metadata.set(
  ~id=Reventless.StateAnnotations.stateAnnotationsId,
  {
    ids: ["productId"],
    compositeIds: [],
    subIds: ["createdAt"],
    compositeSubIds: [],
    indexes: [],
    hidden: [],
    summary: [],
    drillTargets: [],
    drillTargetKeys: [],
    collapsed: [],
    scan: [],
    scanSort: [],
    status: None,
    visibility: None,
  },
)

@schema
type scanState = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  status: string,
  name: string,
  description: string,
}
let scanStateSchemaWithAnnotations = scanStateSchema->S.Metadata.set(
  ~id=Reventless.StateAnnotations.stateAnnotationsId,
  {
    ids: ["productId"],
    compositeIds: [],
    subIds: [],
    compositeSubIds: [],
    indexes: [],
    hidden: [],
    summary: [],
    drillTargets: [],
    drillTargetKeys: [],
    collapsed: [],
    scan: ["status"],
    scanSort: ["name"],
    status: None,
    visibility: None,
  },
)

// ── Granular Level Tests ────────────────────────────────────────────────────

describe("GraphQL_SchemaInspector", () => {
  describe("inspectScalar", () => {
    testPromise("plain string derives to String", async () => {
      expect(ReventlessCore.GraphQL_SchemaInspector.inspectScalar(stringSchema))->toBe("String")
    })

    testPromise("tagged string derives to ID", async () => {
      expect(ReventlessCore.GraphQL_SchemaInspector.inspectScalar(taggedSchema))->toBe("ID")
    })

    testPromise("float derives to Float", async () => {
      expect(ReventlessCore.GraphQL_SchemaInspector.inspectScalar(numberSchema))->toBe("Float")
    })

    testPromise("bool derives to Boolean", async () => {
      expect(ReventlessCore.GraphQL_SchemaInspector.inspectScalar(boolSchema))->toBe("Boolean")
    })
  })

  describe("inspectObjectType", () => {
    testPromise("derives type definition from object schema", async () => {
      let result = ReventlessCore.GraphQL_SchemaInspector.inspectObjectType(
        ~typeName="TestState",
        testStateSchema,
      )
      expect(result->Option.isSome)->toBe(true)
      let sdl = result->Option.getOrThrow
      expect(sdl->String.includes("type TestState"))->toBe(true)
      expect(sdl->String.includes("id: ID!"))->toBe(true)
      expect(sdl->String.includes("name: String"))->toBe(true)
      expect(sdl->String.includes("price: Float"))->toBe(true)
      expect(sdl->String.includes("active: Boolean"))->toBe(true)
    })

    testPromise("returns None for non-object schema", async () => {
      let result = ReventlessCore.GraphQL_SchemaInspector.inspectObjectType(
        ~typeName="Foo",
        stringSchema,
      )
      expect(result->Option.isNone)->toBe(true)
    })
  })

  describe("inspectMutationFields", () => {
    testPromise("derives fields from single-variant (DCB slice) command", async () => {
      let fields = ReventlessCore.GraphQL_SchemaInspector.inspectMutationFields(
        ~fieldPrefix="Catalog_AddProduct",
        addCommandSchema,
      )
      expect(fields->Array.length)->toBe(1)
      let field = fields->Array.getUnsafe(0)
      expect(field->String.includes("Catalog_AddProduct"))->toBe(true)
      expect(field->String.includes("productId: ID!"))->toBe(true)
      expect(field->String.includes("name: String"))->toBe(true)
    })

    testPromise("derives fields from union (aggregate) command", async () => {
      let fields = ReventlessCore.GraphQL_SchemaInspector.inspectMutationFields(
        ~fieldPrefix="App_Item",
        unionCommandSchema,
      )
      expect(fields->Array.length)->toBe(2)
      let createField = fields->Array.getUnsafe(0)
      expect(createField->String.includes("App_Item_Create"))->toBe(true)
      expect(createField->String.includes("itemId: ID!"))->toBe(true)
      let renameField = fields->Array.getUnsafe(1)
      expect(renameField->String.includes("App_Item_Rename"))->toBe(true)
      expect(renameField->String.includes("newName: String"))->toBe(true)
    })

    testPromise("returns empty for non-object/non-union schema", async () => {
      let fields = ReventlessCore.GraphQL_SchemaInspector.inspectMutationFields(
        ~fieldPrefix="Foo",
        stringSchema,
      )
      expect(fields->Array.length)->toBe(0)
    })
  })

  describe("inspectQueryFields", () => {
    testPromise("derives type def and query fields from state schema", async () => {
      let result = ReventlessCore.GraphQL_SchemaInspector.inspectQueryFields(
        ~name="Catalog_Product",
        ~typeName="CatalogProduct",
        testStateSchema,
      )
      expect(result.typeDef->Option.isSome)->toBe(true)
      let typeDef = result.typeDef->Option.getOrThrow
      expect(typeDef->String.includes("type CatalogProduct"))->toBe(true)
      expect(result.singleQuery->String.includes("Catalog_Product(id: ID!)"))->toBe(true)
      expect(result.singleQuery->String.includes("CatalogProduct"))->toBe(true)
      expect(result.listQuery->Option.isSome)->toBe(true)
      let listQ = result.listQuery->Option.getOrThrow
      expect(listQ->String.includes("Catalog_Products"))->toBe(true)
    })
  })

  // ── includeIdParam Tests ──────────────────────────────────────────────────

  describe("includeIdParam — ReadModel vs StateViewSlice", () => {
    testPromise("ReadModel fragment: query has (id: ID!) and type has injected id: ID!", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "RM_Product",
            listFieldName: "RM_Products",
            returnTypeName: "RMProduct",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      expect(sdl->String.includes("RM_Product(id: ID!): RMProduct"))->toBe(true)
      expect(sdl->String.includes("type RMProduct"))->toBe(true)
      // The type should have an injected id: ID! field (first field in the type)
      let typeLines = sdl->String.split("\n")
      let idFieldInType = typeLines->Array.some(line =>
        line->String.trim == "id: ID!" &&
          !(line->String.includes("("))
      )
      expect(idFieldInType)->toBe(true)
    })

    testPromise("StateViewSlice fragment: query has no (id: ID!) and type has no injected id", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "SV_Item",
            listFieldName: "SV_Items",
            returnTypeName: "SVItem",
            stateSchema: svStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: false,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      // Single query should NOT have (id: ID!) parameter
      expect(sdl->String.includes("SV_Item: SVItem"))->toBe(true)
      expect(sdl->String.includes("SV_Item(id: ID!)"))->toBe(false)
      // The type should NOT have an injected id: ID! field
      expect(sdl->String.includes("type SVItem"))->toBe(true)
      expect(sdl->String.includes("productId: ID!"))->toBe(true)
      // Count id: ID! occurrences — should be zero (productId uses ID! but "id: ID!" standalone should not appear)
      let typeSection = sdl->String.split("type SVItem")->Array.get(1)->Option.getOr("")
      let typeEnd = typeSection->String.indexOf("}")
      let typeEnd = typeEnd >= 0 ? typeEnd : typeSection->String.length
      let typeBody = typeSection->String.slice(~start=0, ~end=typeEnd)
      let hasInjectedId = typeBody->String.split("\n")->Array.some(line =>
        line->String.trim == "id: ID!"
      )
      expect(hasInjectedId)->toBe(false)
    })

    testPromise("default includeIdParam (omitted) behaves like ReadModel", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Default_Thing",
            listFieldName: "Default_Things",
            returnTypeName: "DefaultThing",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      expect(sdl->String.includes("Default_Thing(id: ID!): DefaultThing"))->toBe(true)
    })
  })

  // ── Relay compliance — implements Node + Connection types ──────────────

  describe("Relay compliance", () => {
    testPromise("entity type includes 'implements Node' when includeIdParam is true", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Relay_Product",
            listFieldName: "Relay_Products",
            returnTypeName: "RelayProduct",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      expect(sdl->String.includes("type RelayProduct implements Node"))->toBe(true)
      expect(sdl->String.includes("id: ID!"))->toBe(true)
    })

    testPromise("non-entity type does not include 'implements Node'", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Relay_View",
            listFieldName: "Relay_Views",
            returnTypeName: "RelayView",
            stateSchema: svStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: false,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      expect(sdl->String.includes("type RelayView implements Node"))->toBe(false)
      expect(sdl->String.includes("type RelayView {"))->toBe(true)
    })

    testPromise("connectionSpec generates Edge and Connection types instead of plural wrapper", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Relay_Product",
            listFieldName: "Relay_Products",
            returnTypeName: "RelayProduct",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
            connectionSpec: true,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      // Should have Edge and Connection types
      expect(sdl->String.includes("type RelayProductEdge"))->toBe(true)
      expect(sdl->String.includes("node: RelayProduct!"))->toBe(true)
      expect(sdl->String.includes("cursor: String!"))->toBe(true)
      expect(sdl->String.includes("type RelayProductConnection"))->toBe(true)
      expect(sdl->String.includes("edges: [RelayProductEdge!]!"))->toBe(true)
      expect(sdl->String.includes("pageInfo: PageInfo!"))->toBe(true)
      expect(sdl->String.includes("totalCount"))->toBe(false)
      // Query field should use filter + first/after/last/before args (Phase 4)
      expect(
        sdl->String.includes(
          "Relay_Products(filter: RelayProductFilter, first: Int, after: String, last: Int, before: String): RelayProductConnection!",
        ),
      )->toBe(true)
      // Connection filter input with search/searchPrefix/ids
      expect(sdl->String.includes("input RelayProductFilter"))->toBe(true)
      expect(sdl->String.includes("search: String"))->toBe(true)
      expect(sdl->String.includes("searchPrefix: String"))->toBe(true)
      expect(sdl->String.includes("ids: [ID!]"))->toBe(true)
      // Should NOT have legacy plural wrapper type
      expect(sdl->String.includes("items: [RelayProduct!]!"))->toBe(false)
      expect(sdl->String.includes("nextToken:"))->toBe(false)
    })

    testPromise("subIdField generates ItemsFilter (distinct from connection Filter)", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Items_Product",
            listFieldName: "Items_Products",
            returnTypeName: "ItemsProduct",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
            connectionSpec: true,
            subIdField: "sku",
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      // Connection-level filter (search/searchPrefix/ids)
      expect(sdl->String.includes("input ItemsProductFilter"))->toBe(true)
      // Items query gets its own filter type (prefix/from/to/eq/order) — renamed
      // to ItemsFilter to disambiguate from the connection-level Filter.
      expect(sdl->String.includes("input ItemsProductItemsFilter"))->toBe(true)
      expect(
        sdl->String.includes(
          "Items_ProductItems(id: ID!, filter: ItemsProductItemsFilter,",
        ),
      )->toBe(true)
    })

    testPromise("explicit connectionSpec=false generates legacy plural wrapper (opt-out)", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Legacy_Product",
            listFieldName: "Legacy_Products",
            returnTypeName: "LegacyProduct",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
            connectionSpec: false,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      expect(sdl->String.includes("items: [LegacyProduct!]!"))->toBe(true)
      expect(sdl->String.includes("nextToken: String"))->toBe(true)
      expect(sdl->String.includes("LegacyProductEdge"))->toBe(false)
      expect(sdl->String.includes("LegacyProductConnection"))->toBe(false)
    })

    testPromise("stitcher injects Node interface and node query", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Stitch_Product",
            listFieldName: "Stitch_Products",
            returnTypeName: "StitchProduct",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
          },
        ],
      )
      let sdl = ReventlessCore.GraphQL_Stitcher.stitch(~baseFragment=fragment, ~pluginFragments=[])
      expect(sdl->String.includes("interface Node"))->toBe(true)
      expect(sdl->String.includes("node(id: ID!): Node"))->toBe(true)
      expect(sdl->String.includes("type PageInfo"))->toBe(true)
      expect(sdl->String.includes("hasNextPage: Boolean!"))->toBe(true)
    })
  })

  // ── Plugin Level — Fragment Inspector ───────────────────────────────────

  describe("inspectFragment", () => {
    testPromise("decodes and previews a fragment", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[
          {
            fieldNames: ["Test_Add"],
            commandSchema: addCommandSchema->S.castToUnknown,
          },
        ],
        ~queryEntries=[
          {
            singleFieldName: "Test_State",
            listFieldName: "Test_States",
            returnTypeName: "TestState",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      // TestState, TestStateEdge, TestStateConnection, TestStateFilter (Phase 4 connection filter)
      // + CommandResult union + CommandAccepted + CommandRejected + CommandPending
      // (auto-injected whenever the fragment emits any mutation field).
      expect(inspection.types->Array.length)->toBe(8)
      expect(inspection.mutations->Array.length)->toBe(1)
      expect(inspection.queries->Array.length)->toBe(2)
      expect(inspection.sdlPreview->String.includes("type TestState"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("type TestStateEdge"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("type TestStateConnection"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("input TestStateFilter"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("edges: [TestStateEdge!]!"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("Test_Add"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("Test_State"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("TestStateConnection!"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("union CommandResult"))->toBe(true)
    })
  })

  describe("inspectPluginEntries", () => {
    testPromise("formats mutation and query entries", async () => {
      let summary = ReventlessCore.GraphQL_SchemaInspector.inspectPluginEntries(
        ~mutationEntries=[
          {
            fieldNames: ["Plugin_Add", "Plugin_Remove"],
            commandSchema: unionCommandSchema->S.castToUnknown,
          },
        ],
        ~queryEntries=[
          {
            singleFieldName: "Plugin_Item",
            listFieldName: "Plugin_Items",
            returnTypeName: "PluginItem",
            stateSchema: testStateSchema->S.castToUnknown,
            authorization: None,
          },
        ],
      )
      expect(summary->String.includes("Mutations (2)"))->toBe(true)
      expect(summary->String.includes("Plugin_Add"))->toBe(true)
      expect(summary->String.includes("Plugin_Remove"))->toBe(true)
      expect(summary->String.includes("Queries (1)"))->toBe(true)
      expect(summary->String.includes("Plugin_Item(id) -> PluginItem"))->toBe(true)
    })
  })

  // ── Platform Level — GraphQL_Server diagnostics ─────────────────────────

  // ── Phase 1: server capability — auto-derived Filter / OrderBy ─────────

  describe("server capability — auto-derived Filter / OrderBy", () => {
    testPromise("read model with no annotations emits the unchanged search-only Filter", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Plain_View",
            listFieldName: "Plain_Views",
            returnTypeName: "PlainView",
            stateSchema: plainStateSchema->S.castToUnknown,
            authorization: None,
            includeIdParam: false,
            connectionSpec: true,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      // Filter has only the legacy block
      expect(sdl->String.includes("input PlainViewFilter"))->toBe(true)
      expect(sdl->String.includes("search: String"))->toBe(true)
      expect(sdl->String.includes("searchPrefix: String"))->toBe(true)
      expect(sdl->String.includes("ids: [ID!]"))->toBe(true)
      // No per-field eq inputs
      expect(sdl->String.includes("Eq:"))->toBe(false)
      // No OrderBy / OrderField types or arg
      expect(sdl->String.includes("PlainViewOrderBy"))->toBe(false)
      expect(sdl->String.includes("PlainViewOrderField"))->toBe(false)
      expect(sdl->String.includes("orderBy:"))->toBe(false)
    })

    testPromise("read model with @id + @index emits Eq filters + OrderBy + orderBy arg", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Indexed_Product",
            listFieldName: "Indexed_Products",
            returnTypeName: "IndexedProduct",
            stateSchema: indexedStateSchemaWithAnnotations->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
            connectionSpec: true,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      // Per-field eq inputs derived from @id and @index
      expect(sdl->String.includes("input IndexedProductFilter"))->toBe(true)
      expect(sdl->String.includes("productIdEq: ID"))->toBe(true)
      // ownerId is detected as an entity reference → ID (matches SchemaType.fromSury behaviour)
      expect(sdl->String.includes("ownerIdEq: ID"))->toBe(true)
      // OrderField enum lists the same fields
      expect(sdl->String.includes("enum IndexedProductOrderField"))->toBe(true)
      expect(sdl->String.includes("input IndexedProductOrderBy"))->toBe(true)
      expect(sdl->String.includes("direction: SortOrder!"))->toBe(true)
      // Connection field arg list includes orderBy
      expect(sdl->String.includes("orderBy: IndexedProductOrderBy"))->toBe(true)
    })

    testPromise(
      "read model with @scan / @scanSort folds opt-in fields into Filter / OrderBy",
      async () => {
        let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
          ~mutationEntries=[],
          ~queryEntries=[
            {
              singleFieldName: "Scan_Item",
              listFieldName: "Scan_Items",
              returnTypeName: "ScanItem",
              stateSchema: scanStateSchemaWithAnnotations->S.castToUnknown,
              authorization: None,
              includeIdParam: true,
              connectionSpec: true,
            },
          ],
        )
        let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
        let sdl = inspection.sdlPreview
        // @scan field becomes filterable via <field>Eq
        expect(sdl->String.includes("statusEq: String"))->toBe(true)
        // @scan does not promote the field to sortable
        expect(sdl->String.includes("enum ScanItemOrderField"))->toBe(true)
        // @scanSort field appears in OrderField enum
        expect(sdl->String.includes("name"))->toBe(true)
        expect(sdl->String.includes("orderBy: ScanItemOrderBy"))->toBe(true)
        // @scanSort alone does not auto-add an Eq filter for that field
        expect(sdl->String.includes("nameEq:"))->toBe(false)
        // @scan range form is not emitted (eq only)
        expect(sdl->String.includes("statusFrom:"))->toBe(false)
        expect(sdl->String.includes("statusTo:"))->toBe(false)
      },
    )

    testPromise(
      "validateScanSortAlignment warns when @scanSort field is not a sort key",
      async () => {
        // scanStateSchemaWithAnnotations has @scanSort on "name". With no table
        // sort key and no GSIs, "name" is not aligned with any sort key.
        let warnings = ReventlessCore.GraphQL_FragmentGenerator.validateScanSortAlignment(
          ~schema=scanStateSchemaWithAnnotations->S.castToUnknown,
          ~readModelName="ScanItem",
          ~knownSortFields=[],
        )
        expect(warnings->Array.length)->toBe(1)
        let msg = warnings->Array.getUnsafe(0)
        expect(msg->String.includes("ScanItem"))->toBe(true)
        expect(msg->String.includes("name"))->toBe(true)
        expect(msg->String.includes("per-page"))->toBe(true)
      },
    )
    testPromise(
      "validateScanSortAlignment is silent when @scanSort field aligns with a known sort key",
      async () => {
        let warnings = ReventlessCore.GraphQL_FragmentGenerator.validateScanSortAlignment(
          ~schema=scanStateSchemaWithAnnotations->S.castToUnknown,
          ~readModelName="ScanItem",
          ~knownSortFields=["name"],
        )
        expect(warnings)->toEqual([])
      },
    )
    testPromise(
      "validateScanSortAlignment is a no-op when there are no @scanSort fields",
      async () => {
        let warnings = ReventlessCore.GraphQL_FragmentGenerator.validateScanSortAlignment(
          ~schema=indexedStateSchemaWithAnnotations->S.castToUnknown,
          ~readModelName="IndexedProduct",
          ~knownSortFields=[],
        )
        expect(warnings)->toEqual([])
      },
    )
    testPromise("read model with @subId emits range filters + OrderBy on the sort key", async () => {
      let fragment = ReventlessCore.GraphQL_FragmentGenerator.generate(
        ~mutationEntries=[],
        ~queryEntries=[
          {
            singleFieldName: "Ordered_Item",
            listFieldName: "Ordered_Items",
            returnTypeName: "OrderedItem",
            stateSchema: orderedStateSchemaWithAnnotations->S.castToUnknown,
            authorization: None,
            includeIdParam: true,
            connectionSpec: true,
          },
        ],
      )
      let inspection = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment)
      let sdl = inspection.sdlPreview
      expect(sdl->String.includes("createdAtEq: String"))->toBe(true)
      expect(sdl->String.includes("createdAtFrom: String"))->toBe(true)
      expect(sdl->String.includes("createdAtTo: String"))->toBe(true)
      expect(sdl->String.includes("enum OrderedItemOrderField"))->toBe(true)
      expect(sdl->String.includes("orderBy: OrderedItemOrderBy"))->toBe(true)
    })
  })

  describe("GraphQL_Server diagnostics", () => {
    testPromise("diagnostics detects resolver without SDL field", async () => {
      GraphQL_Server.reset()
      let resolvers = Dict.make()
      resolvers->Dict.set("orphanResolver", async (_root, _args, _ctx) => JSON.Encode.string("ok"))
      GraphQL_Server.registerMutations(~sdlFields=[], ~resolvers)
      let d = GraphQL_Server.diagnostics()
      expect(d.resolverMutationCount)->toBe(1)
      expect(d.sdlMutationCount)->toBe(0)
      expect(d.mismatches->Array.length)->toBe(1)
      expect(
        (d.mismatches->Array.getUnsafe(0))->String.includes("resolver but no SDL field"),
      )->toBe(true)
      GraphQL_Server.reset()
    })

    testPromise("diagnostics detects SDL field without resolver", async () => {
      GraphQL_Server.reset()
      GraphQL_Server.registerQueries(
        ~sdlFields=["  orphanField(id: ID!): String"],
        ~resolvers=Dict.make(),
      )
      let d = GraphQL_Server.diagnostics()
      expect(d.sdlQueryCount)->toBe(1)
      expect(d.resolverQueryCount)->toBe(0)
      expect(d.mismatches->Array.length)->toBe(1)
      expect(
        (d.mismatches->Array.getUnsafe(0))->String.includes("SDL field but no resolver"),
      )->toBe(true)
      GraphQL_Server.reset()
    })

    testPromise("diagnostics reports no mismatches when fields and resolvers match", async () => {
      GraphQL_Server.reset()
      let resolvers = Dict.make()
      resolvers->Dict.set("myQuery", async (_root, _args, _ctx) => JSON.Encode.string("ok"))
      GraphQL_Server.registerQueries(
        ~sdlFields=["  myQuery(id: ID!): String"],
        ~resolvers,
      )
      let d = GraphQL_Server.diagnostics()
      expect(d.mismatches->Array.length)->toBe(0)
      expect(d.sdlQueryCount)->toBe(1)
      expect(d.resolverQueryCount)->toBe(1)
      GraphQL_Server.reset()
    })

    testPromise("getFullSdl returns None before start", async () => {
      GraphQL_Server.reset()
      expect(GraphQL_Server.getFullSdl()->Option.isNone)->toBe(true)
    })

    testPromise("getRegisteredSdl returns Query/Mutation SDL", async () => {
      GraphQL_Server.reset()
      GraphQL_Server.registerQueries(
        ~sdlFields=["  hello: String"],
        ~resolvers=Dict.make(),
      )
      let sdl = GraphQL_Server.getRegisteredSdl()
      expect(sdl->String.includes("hello: String"))->toBe(true)
      expect(sdl->String.includes("type Query"))->toBe(true)
      GraphQL_Server.reset()
    })
  })
})
