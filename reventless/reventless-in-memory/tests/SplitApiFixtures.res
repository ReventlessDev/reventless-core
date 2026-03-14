// Fixtures for split API mode integration tests.
// Tests the split routing logic directly using GraphQL_Server (singleton)
// and GraphQL_ServerInstance (factory) without importing Platform or MCP,
// which avoids ESM compatibility issues with Jest.
//
// This mirrors what Platform.makePlatform does in split mode:
// - Admin schema → GraphQL_ServerInstance (isolated admin server)
// - Plugin schema → GraphQL_Server singleton (plugin server)

let _ = TestRunner.setup()

// Derive field names from the schema entries — single source of truth.
let adminQueryEntry =
  ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(0)
let singleQueryField = adminQueryEntry.singleFieldName
let listQueryField = adminQueryEntry.listFieldName
let adminMutationFieldNames =
  ReventlessCore.AdminApi.mutationEntries->Array.flatMap(entry => entry.fieldNames)

// ─────────────────────────────────────────────────────────────
// Create admin GraphQL instance (mirrors Platform split mode)
// ─────────────────────────────────────────────────────────────

let adminGraphQL = GraphQL_ServerInstance.make(~label="GraphQL:Admin")

// Register admin schema into the admin instance
let baseParts = ReventlessCore.GraphQL_Stitcher.decode(ReventlessCore.AdminApi.baseFragment)
let () = adminGraphQL.registerTypes(~sdlTypes=baseParts.types)

let adminQueryResolvers = Dict.make()
let () = adminQueryResolvers->Dict.set(singleQueryField, async (_root, _args): JSON.t => JSON.Encode.null)
let () = adminQueryResolvers->Dict.set(listQueryField, async (_root, _args): JSON.t => JSON.Encode.null)
let () = adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=adminQueryResolvers)

let adminMutationResolvers = Dict.make()
let () = adminMutationFieldNames->Array.forEach(field =>
  adminMutationResolvers->Dict.set(field, async (_root, _args): JSON.t => JSON.Encode.string("ok"))
)
let () = adminGraphQL.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=adminMutationResolvers)

// ─────────────────────────────────────────────────────────────
// Register fake plugin schema into the singleton (plugin server)
// ─────────────────────────────────────────────────────────────

let () = GraphQL_Server.reset()

let pluginTypes = [`type SplitTestPlugin_SplitTestItem { id: ID!, name: String! }`]
let () = GraphQL_Server.registerTypes(~sdlTypes=pluginTypes)

let pluginQueryResolvers = Dict.make()
let () = pluginQueryResolvers->Dict.set("SplitTestPlugin_SplitTestItem", async (_root, _args): JSON.t => JSON.Encode.null)
let () = pluginQueryResolvers->Dict.set("SplitTestPlugin_SplitTestItems", async (_root, _args): JSON.t => JSON.Encode.null)
let () = GraphQL_Server.registerQueries(
  ~sdlFields=[
    `SplitTestPlugin_SplitTestItem(id: ID!): SplitTestPlugin_SplitTestItem`,
    `SplitTestPlugin_SplitTestItems(nextToken: String, limit: Int): SplitTestPlugin_SplitTestItem`,
  ],
  ~resolvers=pluginQueryResolvers,
)

let pluginMutationResolvers = Dict.make()
let () = pluginMutationResolvers->Dict.set("SplitTestPlugin_SplitTestItem_CreateItem", async (_root, _args): JSON.t => JSON.Encode.string("ok"))
let () = GraphQL_Server.registerMutations(
  ~sdlFields=[`SplitTestPlugin_SplitTestItem_CreateItem(id: ID!, name: String!): String`],
  ~resolvers=pluginMutationResolvers,
)
