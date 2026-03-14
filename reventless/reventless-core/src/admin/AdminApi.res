open ReventlessInfra.Api

@schema
type cloneArgs = {restoreDateTime?: string}

let cloneMutationEntry: mutationSchemaEntry = {
  fieldNames: [Api_Naming.adminField(~name="Clone")],
  commandSchema: cloneArgsSchema->S.castToUnknown,
  description: "Clone the system to a specific point in time",
}

let mutationEntries: array<mutationSchemaEntry> = Array.concat(
  PluginBaseFragment.mutationEntries,
  [cloneMutationEntry],
)

let queryEntries = PluginBaseFragment.queryEntries

let baseFragment = GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)
