// Tests for GraphQL_SchemaInspector — verifies schema introspection at granular,
// plugin-fragment, and platform levels.

open AsyncTest
open AsyncTest.Expect

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
type addCommand = {
  productId: @s.matches(Reventless.DcbTag.string) string,
  name: string,
}

@schema
type unionCommand =
  | Create({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | Rename({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})

// ── Granular Level Tests ────────────────────────────────────────────────────

describe("GraphQL_SchemaInspector", () => {
  describe("inspectScalar", () => {
    testPromise("plain string derives to String", async () => {
      expect(ReventlessCore.GraphQL_SchemaInspector.inspectScalar(stringSchema))->toBe("String")
    })

    testPromise("tagged string derives to ID!", async () => {
      expect(ReventlessCore.GraphQL_SchemaInspector.inspectScalar(taggedSchema))->toBe("ID!")
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
      expect(inspection.types->Array.length)->toBe(2)
      expect(inspection.mutations->Array.length)->toBe(1)
      expect(inspection.queries->Array.length)->toBe(2)
      expect(inspection.sdlPreview->String.includes("type TestState"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("type Test_States"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("items: [TestState!]!"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("Test_Add"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("Test_State"))->toBe(true)
      expect(inspection.sdlPreview->String.includes("Test_States!"))->toBe(true)
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

  describe("GraphQL_Server diagnostics", () => {
    testPromise("diagnostics detects resolver without SDL field", async () => {
      GraphQL_Server.reset()
      let resolvers = Dict.make()
      resolvers->Dict.set("orphanResolver", async (_root, _args) => JSON.Encode.string("ok"))
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
      resolvers->Dict.set("myQuery", async (_root, _args) => JSON.Encode.string("ok"))
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
