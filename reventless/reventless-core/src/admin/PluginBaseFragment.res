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

// Arg schemas for payload-less admin mutations
@schema
type activateArgs = {id: @s.matches(Reventless.DcbTag.string) string}

@schema
type deactivateArgs = {id: @s.matches(Reventless.DcbTag.string) string}

let mutationEntries: array<mutationSchemaEntry> = [
  {
    fieldNames: [Api_Naming.adminField(~name="Plugin_Activate")],
    commandSchema: activateArgsSchema->S.castToUnknown,
    description: "Activate a plugin by ID",
  },
  {
    fieldNames: [Api_Naming.adminField(~name="Plugin_Deactivate")],
    commandSchema: deactivateArgsSchema->S.castToUnknown,
    description: "Deactivate a plugin by ID",
  },
]

let fragment = GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
