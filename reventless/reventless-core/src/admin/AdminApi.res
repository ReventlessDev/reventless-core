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

// UIFragment lifecycle Source C subscriptions.
// Mutations are called by the backend when UIFragment events occur;
// AppSync routes via @aws_subscribe to onUIFragmentChange subscribers.
// manifest is serialised as a JSON string (String scalar, not AWSJSON).

let uiFragmentSubscriptionTypes = [
  `enum UIFragmentChangeKind {\n  Registered\n  Updated\n  Deregistered\n}`,
  `type UIFragmentChangeEvent {\n  pluginId: ID!\n  changeKind: UIFragmentChangeKind!\n  manifest: String\n}`,
]

let uiFragmentMutationFields = [
  `  Platform_UIFragmentRegistered(pluginId: ID!, manifest: String): UIFragmentChangeEvent`,
  `  Platform_UIFragmentUpdated(pluginId: ID!, manifest: String): UIFragmentChangeEvent`,
  `  Platform_UIFragmentDeregistered(pluginId: ID!): UIFragmentChangeEvent`,
]

let uiFragmentSubscriptionField = `  onUIFragmentChange: UIFragmentChangeEvent\n    @aws_subscribe(mutations: ["Platform_UIFragmentRegistered", "Platform_UIFragmentUpdated", "Platform_UIFragmentDeregistered"])`

let baseFragment = (~cloner: bool) => {
  let base = GraphQL_FragmentGenerator.generate(~mutationEntries=mutationEntries(~cloner), ~queryEntries)
  let parts = GraphQL_Stitcher.decode(base)
  GraphQL_Stitcher.encode({
    ...parts,
    types: Array.concat(parts.types, uiFragmentSubscriptionTypes),
    mutations: Array.concat(parts.mutations, uiFragmentMutationFields),
    subscriptions: [uiFragmentSubscriptionField],
  })
}
