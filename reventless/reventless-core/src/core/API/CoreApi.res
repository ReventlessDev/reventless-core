open ReventlessInfra.Api

@schema
type cloneArgs = {restoreDateTime?: string}

let mutationEntries: array<mutationSchemaEntry> = Array.concat(
  PluginBaseFragment.mutationEntries,
  [
    {
      fieldNames: [Api_Naming.coreField(~name="Clone")],
      commandSchema: cloneArgsSchema->S.castToUnknown,
      description: "Clone the system to a specific point in time",
    },
  ],
)

let queryEntries = PluginBaseFragment.queryEntries

let baseFragment = GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)

let generateFragment = (
  ~dcbMutationEntries: array<mutationSchemaEntry>,
  ~dcbQueryEntries: array<querySchemaEntry>,
  ~dcbEventLogEntries: array<eventLogSchemaEntry>,
) => {
  let allMutationEntries = Array.concat(mutationEntries, dcbMutationEntries)
  let allQueryEntries = Array.concat(queryEntries, dcbQueryEntries)
  let _ = dcbEventLogEntries
  GraphQL_FragmentGenerator.generate(~mutationEntries=allMutationEntries, ~queryEntries=allQueryEntries)
}
