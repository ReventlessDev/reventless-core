// Fixtures for split API mode integration tests.
// Tests the split routing logic directly using GraphQL_Server (singleton)
// and ReventlessGraphqlServer.GraphQL_ServerInstance (factory) without importing Platform or MCP,
// which avoids ESM compatibility issues with Jest.
//
// This mirrors what Platform.makePlatform does in split mode:
// - Admin schema → ReventlessGraphqlServer.GraphQL_ServerInstance (isolated admin server)
// - Plugin schema → GraphQL_Server singleton (plugin server)

let _ = TestRunner.setup()

// Helper to extract resolver key from an SDL field string.
// Mirrors ReventlessGraphqlServer.GraphQL_ServerInstance.extractFieldName.
let extractSdlFieldName = (sdlField: string): string => {
  let trimmed = sdlField->String.trim
  trimmed
  ->String.split("(")
  ->Array.get(0)
  ->Option.getOr("")
  ->String.trim
  ->String.split(":")
  ->Array.get(0)
  ->Option.getOr("")
  ->String.trim
}

// ─────────────────────────────────────────────────────────────
// Create admin GraphQL instance (mirrors Platform split mode)
// ─────────────────────────────────────────────────────────────

let adminGraphQL = ReventlessGraphqlServer.GraphQL_ServerInstance.make(~label="GraphQL:Admin")

// Build admin SDL — authoritative source for field names.
let baseParts = ReventlessCore.GraphQL_Stitcher.decode(ReventlessCore.AdminApi.baseFragment(~cloner=true))
let () = adminGraphQL.registerTypes(~sdlTypes=baseParts.types)

// Derive query/mutation field names directly from SDL so that any SDL
// additions (e.g. UIFragment entries) automatically get stub resolvers.
let adminQueryFieldNames = baseParts.queries->Array.map(extractSdlFieldName)
let adminMutationFieldNames = baseParts.mutations->Array.map(extractSdlFieldName)

// Keep these for backwards-compat with the test file.
let adminQueryEntry = ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(0)
let singleQueryField = adminQueryEntry.singleFieldName
let listQueryField = adminQueryEntry.listFieldName

let adminQueryResolvers = Dict.make()
let () = adminQueryFieldNames->Array.forEach(field =>
  adminQueryResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t => JSON.Encode.null)
)
let () = adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=adminQueryResolvers)

let adminMutationResolvers = Dict.make()
let () = adminMutationFieldNames->Array.forEach(field =>
  adminMutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t => JSON.Encode.string("ok"))
)
let () = adminGraphQL.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=adminMutationResolvers)

// ─────────────────────────────────────────────────────────────
// Register fake plugin schema into the singleton (plugin server)
// ─────────────────────────────────────────────────────────────

let () = GraphQL_Server.reset()

let pluginTypes = [`type SplitTestPlugin_SplitTestItem { id: ID!, name: String! }`]
let () = GraphQL_Server.registerTypes(~sdlTypes=pluginTypes)

let pluginQueryResolvers = Dict.make()
let () = pluginQueryResolvers->Dict.set("SplitTestPlugin_SplitTestItem", async (_root, _args, _ctx): JSON.t => JSON.Encode.null)
let () = pluginQueryResolvers->Dict.set("SplitTestPlugin_SplitTestItems", async (_root, _args, _ctx): JSON.t => JSON.Encode.null)
let () = GraphQL_Server.registerQueries(
  ~sdlFields=[
    `SplitTestPlugin_SplitTestItem(id: ID!): SplitTestPlugin_SplitTestItem`,
    `SplitTestPlugin_SplitTestItems(nextToken: String, limit: Int): SplitTestPlugin_SplitTestItem`,
  ],
  ~resolvers=pluginQueryResolvers,
)

let pluginMutationResolvers = Dict.make()
let () = pluginMutationResolvers->Dict.set("SplitTestPlugin_SplitTestItem_CreateItem", async (_root, _args, _ctx): JSON.t => JSON.Encode.string("ok"))
let () = GraphQL_Server.registerMutations(
  ~sdlFields=[`SplitTestPlugin_SplitTestItem_CreateItem(id: ID!, name: String!): String`],
  ~resolvers=pluginMutationResolvers,
)
