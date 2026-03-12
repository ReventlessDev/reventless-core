open ReventlessInfra.Api

let adminAuth: Reventless.ReadModel.authorization = {
  tableName: "Plugin",
  group: "Admin",
}

let queryEntries: array<querySchemaEntry> = [
  {
    singleFieldName: "Core_Plugin",
    listFieldName: "Core_Plugins",
    returnTypeName: "Core_Plugin",
    stateSchema: PluginReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: ["apiSchemaFragment", "eventCollector", "extensionPointNames", "extensionNames"],
  },
]

let fragment = {
  let typesAndQueries = GraphQL_FragmentGenerator.generate(
    ~mutationEntries=[],
    ~queryEntries,
  )

  let parts = GraphQL_Stitcher.decode(typesAndQueries)

  // Add mutations for payload-less aggregate commands (Activate, Deactivate)
  let pluginMutations = [
    `  Core_Plugin_Activate(id: ID!): String!`,
    `  Core_Plugin_Deactivate(id: ID!): String!`,
  ]

  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(parts.types->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(pluginMutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(parts.queries->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify

  {Reventless.Plugin.encoded, protocol: "graphql"}
}
