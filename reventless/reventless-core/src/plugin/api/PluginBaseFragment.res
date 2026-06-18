open ReventlessInfra.Api

let adminAuth: Reventless.ReadModel.authorization = {
  tableName: "Plugin",
  group: "Admin",
}

// Fields present on `PluginsReadModelSpec.state` for projection/storage purposes
// but intentionally absent from the public GraphQL surface. Shared with
// `Platform_Admin_Structure` so the schema announced via `Platform_ComponentDefinitions`
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
// callers (host-shell's Platform_ComponentDefinitions / Platform_UIFragments /
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
    // The read-model `Spec.name` is "Plugins" (plural — the read-model cluster
    // is named after the list, see `PluginsReadModelSpec`), while the GraphQL
    // return type stays singular as `Platform_Plugin`. `specName` is what
    // `QueryDbResolvers_{AppSync,GraphQL}.make` looks up in
    // `queryFieldNamesRegistry`, so it must match `Spec.name`, not the
    // singular form derived from `returnTypeName`.
    specName: PluginsReadModelSpec.name,
    singleFieldName: Api_Naming.adminField(~name="Plugin"),
    listFieldName: Api_Naming.adminField(~name="Plugins"),
    returnTypeName: Api_Naming.adminField(~name="Plugin"),
    stateSchema: PluginsReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: pluginExcludeFields,
  },
  {
    specName: Platform_EventGraphReadModelSpec.name,
    singleFieldName: Api_Naming.adminField(~name="PlatformEventGraph"),
    listFieldName: Api_Naming.adminField(~name="PlatformEventGraphs"),
    returnTypeName: Api_Naming.adminField(~name="PlatformEventGraph"),
    stateSchema: Platform_EventGraphReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: [],
  },
  {
    // Composite-key timeline read model (partition = plugin name, sort =
    // transitionKey). The list field returns the whole audit trail; the resolver
    // layer handles the sub-id automatically (QueryDbResolvers_AppSync ~subIdField).
    specName: PluginHistoryReadModelSpec.name,
    singleFieldName: Api_Naming.adminField(~name="PluginHistoryEntry"),
    listFieldName: Api_Naming.adminField(~name="PluginHistory"),
    returnTypeName: Api_Naming.adminField(~name="PluginHistoryEntry"),
    stateSchema: PluginHistoryReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: [],
  },
]

// Plugin aggregate admin mutations — derived statically from PluginSpec.command,
// so the generated SDL contains one field per non-`@noApi` variant carrying that
// variant's command fields as args. Since the admin commands are name-keyed and
// version-scoped (`Activate(version)` / `Deactivate(version)` / `Retire(version)`),
// the fields are e.g. `Platform_Plugin_Activate(id: ID!, _0: String!): CommandResult!`
// (`id` = plugin name = aggregate instance; `_0` = target version). `Retire` is
// API-exposed (manual archive, §2.5). Internal-protocol variants (`Heartbeat`,
// `Connect`, `Disconnect`, `ReportIncompatibility`) carry `@noApi` and are filtered
// out by `ApiNoApiHelpers.filterNoApiVariants`. The same `commandSchema`-driven
// entry feeds the MCP tool generator, so the MCP tools gain the version arg and
// the `Plugin_Retire` tool automatically.
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
