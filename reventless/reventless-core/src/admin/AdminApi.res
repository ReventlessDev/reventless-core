open ReventlessInfra.Api

@schema
type cloneArgs = {restoreDateTime?: string}

let cloneMutationEntry: mutationSchemaEntry = {
  fieldNames: [Api_Naming.adminField(~name="Clone")],
  commandSchema: cloneArgsSchema->S.castToUnknown,
  description: "Clone the system to a specific point in time",
}

// Aggregate-derived admin mutations come from
// `PluginBaseFragment.pluginAggregateMutationEntries` so they end up in the
// stitched SDL (the AWS path pushes `AdminApi.baseFragment` directly). The
// corresponding resolver wiring is fired in parallel by
// `Plugin_Helpers.registerAdminAggregateMutations` from `Platform_Admin.construct`.
let mutationEntries = (~cloner: bool) => {
  let base = PluginBaseFragment.pluginAggregateMutationEntries
  if cloner {
    Array.concat(base, [cloneMutationEntry])
  } else {
    base
  }
}

let queryEntries = PluginBaseFragment.queryEntries

// UIFragment lifecycle Source C subscriptions.
// Mutations are called by the backend when UIFragment events occur; the
// subscription→mutation fan-in is carried as neutral `subscriptionSource`
// metadata (providers add their own routing — AppSync via `@aws_subscribe`
// appended at push time, the local platform via its PubSub bridge).
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

let uiFragmentSubscriptionField = `  onUIFragmentChange: UIFragmentChangeEvent`

let uiFragmentSubscriptionSource: GraphQL_Stitcher.subscriptionSource = {
  field: "onUIFragmentChange",
  mutations: [
    "Platform_UIFragmentRegistered",
    "Platform_UIFragmentUpdated",
    "Platform_UIFragmentDeregistered",
  ],
}

// Plugin lifecycle Source C subscription. Mirrors the UIFragment pattern: the
// platform invokes `Platform_PluginStatusChanged` after writing the new status
// to the Plugin read model; the provider routes that mutation to live
// `onPluginStatusChange` subscribers (host shell). The status enum
// matches `PluginsReadModelSpec.status` so consumers can mirror tier 1 / tier 2
// transitions exactly.
let pluginStatusSubscriptionTypes = [
  `enum PluginStatus {\n  Connected\n  Disconnected\n  Inactive\n  Retired\n}`,
  `type PluginStatusChangeEvent {\n  pluginId: ID!\n  status: PluginStatus!\n}`,
]

let pluginStatusMutationFields = [
  `  Platform_PluginStatusChanged(pluginId: ID!, status: PluginStatus!): PluginStatusChangeEvent`,
]

let pluginStatusSubscriptionField = `  onPluginStatusChange: PluginStatusChangeEvent`

let pluginStatusSubscriptionSource: GraphQL_Stitcher.subscriptionSource = {
  field: "onPluginStatusChange",
  mutations: ["Platform_PluginStatusChanged"],
}

let baseFragment = (~cloner: bool) => {
  let base = GraphQL_FragmentGenerator.generate(~mutationEntries=mutationEntries(~cloner), ~queryEntries)
  let parts = GraphQL_Stitcher.decode(base)
  // Source C subscriptions for the admin Plugin aggregate mutations.
  // The standard auto-resolver flow (CommandGeneratorResolvers_AppSync.make)
  // always creates a Subscription.onX resolver per mutation field; without the
  // matching SDL fields, AppSync's CreateResolver fails with "Type not found".
  let (pluginAggregateSubscriptionFields, pluginAggregateSubscriptionSources) =
    Plugin_SubscriptionSchema.sourceCFields(~mutationEntries=PluginBaseFragment.pluginAggregateMutationEntries)
  GraphQL_Stitcher.encode({
    types: parts.types
    ->Array.concat(uiFragmentSubscriptionTypes)
    ->Array.concat(pluginStatusSubscriptionTypes)
    ->Array.concat(Platform_ComponentDefinitionsApi.sdlTypes)
    ->Array.concat(Platform_UIFragmentsApi.sdlTypes)
    ->Array.concat(Platform_ApiFragmentsApi.sdlTypes),
    queries: Array.concat(
      parts.queries,
      [
        Platform_ComponentDefinitionsApi.sdlQueryField,
        Platform_UIFragmentsApi.sdlQueryField,
        Platform_ApiFragmentsApi.sdlQueryField,
      ],
    ),
    mutations: parts.mutations
    ->Array.concat(uiFragmentMutationFields)
    ->Array.concat(pluginStatusMutationFields),
    subscriptions: [uiFragmentSubscriptionField, pluginStatusSubscriptionField]
    ->Array.concat(pluginAggregateSubscriptionFields),
    subscriptionSources: [uiFragmentSubscriptionSource, pluginStatusSubscriptionSource]
    ->Array.concat(pluginAggregateSubscriptionSources),
  })
}
