open ReventlessInfra.Api

@schema
type cloneArgs = {restoreDateTime?: string}

let cloneMutationEntry: mutationSchemaEntry = {
  fieldNames: [Api_Naming.adminField(~name="Clone")],
  commandSchema: cloneArgsSchema->S.castToUnknown,
  description: "Clone the system to a specific point in time",
}

let mutationEntries = (~cloner: bool) =>
  if cloner {
    Array.concat(PluginBaseFragment.mutationEntries, [cloneMutationEntry])
  } else {
    PluginBaseFragment.mutationEntries
  }

let queryEntries = PluginBaseFragment.queryEntries

let baseFragment = (~cloner: bool) =>
  GraphQL_FragmentGenerator.generate(~mutationEntries=mutationEntries(~cloner), ~queryEntries)
