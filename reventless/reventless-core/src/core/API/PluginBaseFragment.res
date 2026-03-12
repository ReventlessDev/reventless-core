open ReventlessInfra.Api

let adminAuth: Reventless.ReadModel.authorization = {
  tableName: "Plugin",
  group: "Admin",
}

let queryEntries: array<querySchemaEntry> = [
  {
    singleFieldName: "plugin",
    listFieldName: None,
    returnTypeName: "Plugin",
    stateSchema: PluginReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: ["apiSchemaFragment", "eventCollector", "extensionPointNames", "extensionNames"],
  },
]

let fragment = {
  // Generate the Plugin type and single-item query from the read model state schema
  let typesAndQueries = GraphQL_FragmentGenerator.generate(
    ~mutationEntries=[],
    ~queryEntries,
  )

  let parts = GraphQL_Stitcher.decode(typesAndQueries)

  // Add the plural wrapper type (Plugins) and list query (everyPlugin) manually
  // because the list field name differs from the plural type name.
  let pluralWrapperType = GraphQL_FragmentGenerator.derivePluralWrapperType(
    ~pluralTypeName="Plugins",
    ~singularTypeName="Plugin",
  )
  let allTypes = Array.concat(parts.types, [pluralWrapperType])

  let listQuery = `  everyPlugin(nextToken: String, limit: Int): Plugins!`
  let allQueries = Array.concat(parts.queries, [listQuery])

  // Add mutations for payload-less aggregate commands (Activate, Deactivate)
  let pluginMutations = [
    `  Plugin_Activate(id: ID!): String!`,
    `  Plugin_Deactivate(id: ID!): String!`,
  ]

  let encoded =
    JSON.Encode.object(
      Dict.fromArray([
        ("types", JSON.Encode.array(allTypes->Array.map(JSON.Encode.string))),
        ("mutations", JSON.Encode.array(pluginMutations->Array.map(JSON.Encode.string))),
        ("queries", JSON.Encode.array(allQueries->Array.map(JSON.Encode.string))),
      ]),
    )->JSON.stringify

  {Reventless.Plugin.encoded, protocol: "graphql"}
}
