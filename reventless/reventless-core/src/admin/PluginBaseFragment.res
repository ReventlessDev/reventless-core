open ReventlessInfra.Api

let adminAuth: Reventless.ReadModel.authorization = {
  tableName: "Plugin",
  group: "Admin",
}

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
    singleFieldName: Api_Naming.adminField(~name="UIFragment"),
    listFieldName: Api_Naming.adminField(~name="UIFragments"),
    returnTypeName: Api_Naming.adminField(~name="UIFragment"),
    stateSchema: UIFragmentRegistryReadModelSpec.stateSchema->S.castToUnknown,
    authorization: Some(adminAuth),
    excludeFields: ["registeredAt"],
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
