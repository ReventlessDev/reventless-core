open ReventlessInfra.Api

let adminAuth: Reventless.ReadModel.authorization = {
  tableName: "Plugin",
  group: "Admin",
}

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
    excludeFields: ["eventCollector", "extensionPointNames", "extensionNames"],
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

// Plugin_Activate / Plugin_Deactivate mutation entries are no longer hand-rolled here.
// They are derived from `PluginSpec.command` by `Plugin_Helpers.registerAdminAggregateMutations`
// during `Platform_Admin.construct`, which also wires the resolver/SDL hooks. Internal-protocol
// variants (`Heartbeat`, `Connect`, `Disconnect`, `ReportIncompatibility`) carry `@noApi` so they
// are filtered out before the GraphQL fragment is generated.
