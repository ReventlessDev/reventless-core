open ReventlessInfra.Api

let adminAuth: Reventless.ReadModel.authorization = {
  tableName: "Plugin",
  group: "Admin",
}

// Fields present on `PluginReadModelSpec.state` for projection/storage purposes
// but intentionally absent from the public GraphQL surface. Shared with
// `Platform_Admin_Structure` so the schema announced via `Platform_UIDefinitions`
// stays aligned with the SDL — otherwise AutoUI generates list-view queries
// for fields the server doesn't expose and every Plugin row fails to load.
let pluginExcludeFields: array<string> = [
  "eventCollector",
  "extensionPointNames",
  "extensionNames",
]

// Additional fields the SDL exposes but the Plugin list view should NOT
// surface — they're option-of-nested-object types (e.g. apiSchemaFragment,
// uiFragments, structure) which AutoUI currently renders as scalar columns
// and queries without a sub-selection, failing schema validation. Other
// callers (host-shell's Platform_UIDefinitions / Platform_UIFragments /
// Platform_PlatformEventGraphs) keep querying them via dedicated fields
// and resolver paths.
let pluginUIOnlyExcludeFields: array<string> = pluginExcludeFields->Array.concat([
  "apiSchemaFragment",
  "uiFragments",
  "structure",
])

// The UIFragmentRegistry read model is queried exclusively via the explicit
// flat `Platform_UIFragments: [Platform_UIFragmentEntry!]!` field declared in
// `Platform_UIFragmentsApi.res` (and resolved by `Platform_UIFragments_Lambda.res`
// on AWS / the seeded QueryDb in-memory). Reintroducing an auto-generated
// connection field here collides with that name on SDL composition.
let queryEntries: array<querySchemaEntry> = [
  {
    singleFieldName: Api_Naming.adminField(~name="Plugin"),
    listFieldName: Api_Naming.adminField(~name="Plugins"),
    returnTypeName: Api_Naming.adminField(~name="Plugin"),
    stateSchema: PluginReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: pluginExcludeFields,
  },
  {
    singleFieldName: Api_Naming.adminField(~name="PlatformEventGraph"),
    listFieldName: Api_Naming.adminField(~name="PlatformEventGraphs"),
    returnTypeName: Api_Naming.adminField(~name="PlatformEventGraph"),
    stateSchema: Platform_EventGraphReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: [],
  },
]

// Plugin aggregate admin mutations — derived statically from PluginSpec.command
// so the generated SDL contains `Platform_Plugin_Activate(id: ID!): CommandResult!`
// and `Platform_Plugin_Deactivate(id: ID!): CommandResult!`. Internal-protocol
// variants (`Heartbeat`, `Connect`, `Disconnect`, `ReportIncompatibility`) carry
// `@noApi` and are filtered out by `ApiNoApiHelpers.filterNoApiVariants`.
//
// The matching resolver wiring (registry population + `mutationResolverHook` /
// `mutationBindHook` firing for the in-memory and AWS auto-flow) lives in
// `Plugin_Helpers.registerAdminAggregateMutations`, invoked from
// `Platform_Admin.construct` over the `~aggregates` parameter. Both paths derive
// the same field names so the SDL and the resolvers stay aligned.
let pluginAggregateMutationEntries: array<mutationSchemaEntry> = {
  let commandSchema = PluginSpec.commandSchema->S.castToUnknown
  let constructorNames = Reventless.DcbTag.extractAllVariantNames(PluginSpec.commandSchema)
  let filteredConstructorNames =
    ApiNoApiHelpers.filterNoApiVariants(constructorNames, commandSchema)
  let fieldNames =
    filteredConstructorNames->Array.map(cname =>
      Api_Naming.adminField(~name=PluginSpec.name ++ "_" ++ cname)
    )
  if fieldNames->Array.length === 0 {
    []
  } else {
    [
      {
        ReventlessInfra.Api.fieldNames,
        commandSchema,
      },
    ]
  }
}
