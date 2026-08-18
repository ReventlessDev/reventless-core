open ReventlessInfra.Api

// Admin read-model query entries are generated from each spec the same way
// ordinary read models are (Plugin_Builder.res): `subIdField` flows from the
// spec's `subIdConfig` and `indexQueries` from `config.indexes`, so
// `GraphQL_FragmentGenerator` emits the matching `<single>Items` (composite key)
// and `<single>By<Index>` (GSI) fields automatically — in lockstep with the
// shared resolver layer (`QueryDbResolvers_{AppSync,GraphQL}`). This closes the
// admin/ordinary parity gap: an admin read model that declares a sub-id or an
// `@index` now gets the same auto-generated GraphQL surface ordinary read models
// do, instead of just `single` + `list`.
let indexQueriesOfConfig = (config: Reventless.ReadModel.config) =>
  config.indexes->Array.length > 0 ? Some(config.indexes) : None

// The UiFragments StateViewSlice is queried exclusively via the explicit
// flat `Platform_UIFragments: [Platform_UIFragmentEntry!]!` field declared in
// `Platform_UIFragmentsApi.res` (and resolved by `Platform_UIFragments_Lambda.res`
// on AWS / the slice QueryDb in-memory). Reintroducing an auto-generated
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
    // Read off the spec rather than restated. The hand-written
    // `{tableName: "Plugin", group: "Admin"}` that used to sit here said the same
    // thing as `Spec.authorization` in a different type, and the spec's default
    // (`AllowAuthenticated`) disagreed with it — so the view's rule depended on
    // which of the two a reader happened to find. The `tableName` half was never
    // read: the entry path uses only the group, and the per-`@index` auth-table
    // pipeline params come from `indexConfig.authorization`, which is untouched.
    authorization: None,
    permission: PluginsReadModelSpec.authorization,
    // No `excludeFields`: the three fields this entry used to name are declared
    // `@internal` on the spec, and `deriveObjectTypeWithNested` reads that off the
    // schema itself.
    subIdField: ?PluginsReadModelSpec.subIdConfig->Option.map((c: Reventless.ReadModel.subIdConfig<_>) => c.subIdField),
    indexQueries: ?indexQueriesOfConfig(PluginsReadModelSpec.config),
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
