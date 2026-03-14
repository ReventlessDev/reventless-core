// Fixtures for split API mode integration tests.
// Tests the split routing logic directly using GraphQL_Server (singleton)
// and GraphQL_ServerInstance (factory) without importing Platform or MCP,
// which avoids ESM compatibility issues with Jest.
//
// This mirrors what Platform.makePlatform does in split mode:
// - Core schema → GraphQL_ServerInstance (isolated core server)
// - Plugin schema → GraphQL_Server singleton (plugin server)

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Create core GraphQL instance (mirrors Platform split mode)
// ─────────────────────────────────────────────────────────────

let coreGraphQL = GraphQL_ServerInstance.make(~label="GraphQL:Core")

// Register core schema into the core instance
let baseParts = ReventlessCore.GraphQL_Stitcher.decode(ReventlessCore.CoreApi.baseFragment)
let () = coreGraphQL.registerTypes(~sdlTypes=baseParts.types)

let coreQueryResolvers = Dict.make()
let () = coreQueryResolvers->Dict.set("Core_Plugin", async (_root, _args): JSON.t => JSON.Encode.null)
let () = coreQueryResolvers->Dict.set("Core_Plugins", async (_root, _args): JSON.t => JSON.Encode.null)
let () = coreGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=coreQueryResolvers)

let coreMutationResolvers = Dict.make()
let () = coreMutationResolvers->Dict.set("Core_Plugin_Activate", async (_root, _args): JSON.t => JSON.Encode.string("ok"))
let () = coreMutationResolvers->Dict.set("Core_Plugin_Deactivate", async (_root, _args): JSON.t => JSON.Encode.string("ok"))
let () = coreMutationResolvers->Dict.set("Core_Clone", async (_root, _args): JSON.t => JSON.Encode.string("ok"))
let () = coreGraphQL.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=coreMutationResolvers)

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
