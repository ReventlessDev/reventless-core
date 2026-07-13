open ReventlessInfra.Api

@schema
type cloneArgs = {restoreDateTime?: string}

let cloneMutationEntry: mutationSchemaEntry = {
  fieldNames: [Api_Naming.adminField(~name="Clone")],
  commandSchema: cloneArgsSchema->S.castToUnknown,
  description: "Clone the system to a specific point in time",
}

// ApiFragmentRegistry admin mutations — the real GraphQL surface of the ApiFragmentRegistry
// singleton aggregate: the plugin / standalone-service deploy calls
// `Platform_ApiFragmentRegistry_RegisterApiFragment` / `..._DeregisterApiFragment` as a SigV4
// system caller. Derived from the aggregate's `commandSchema` exactly like the Plugin aggregate's
// entries (`PluginBaseFragment.pluginAggregateMutationEntries`) — one `Platform_<Spec>_<Command>`
// field per non-`@noApi` variant (`RecordApiFragmentPush` is `@noApi`, filtered out). The matching
// resolver wiring is fired by `Plugin_Helpers.registerAdminAggregateMutations` over the same
// `~aggregates` list in `Platform_Admin.construct`, so the SDL field and the auto-bound resolver
// carry byte-identical names.
let apiFragmentRegistryMutationEntries: array<mutationSchemaEntry> = {
  let commandSchema = ApiFragmentRegistrySpec.commandSchema->S.castToUnknown
  let constructorNames = Reventless.DcbTag.extractAllVariantNames(ApiFragmentRegistrySpec.commandSchema)
  let filteredConstructorNames = ApiNoApiHelpers.filterNoApiVariants(constructorNames, commandSchema)
  let fieldNames =
    filteredConstructorNames->Array.map(cname =>
      Api_Naming.adminField(~name=ApiFragmentRegistrySpec.name ++ "_" ++ cname)
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

// Aggregate-derived admin mutations come from `PluginBaseFragment.pluginAggregateMutationEntries`
// (Plugin aggregate) + `apiFragmentRegistryMutationEntries` (ApiFragmentRegistry aggregate) so they
// end up in the stitched SDL AND in the static `baseFragment` the AWS path pushes directly. The
// corresponding resolver wiring is fired in parallel by
// `Plugin_Helpers.registerAdminAggregateMutations` from `Platform_Admin.construct` over the same
// `~aggregates` list.
let mutationEntries = (~cloner: bool) => {
  let base = Array.concat(
    PluginBaseFragment.pluginAggregateMutationEntries,
    apiFragmentRegistryMutationEntries,
  )
  if cloner {
    Array.concat(base, [cloneMutationEntry])
  } else {
    base
  }
}

let queryEntries = PluginBaseFragment.queryEntries

// Admin fields a deploy-time system caller (machine credentials — SigV4/IAM on AWS) invokes: the
// two ApiFragmentRegistry mutations (the deploy's register/deregister write path) and
// `Platform_ApiFragments` (the deploy waiter's push-status poll). Provider-neutral by design — the
// AWS adapter threads these into `injectAwsAuthAll`'s `~iamFieldNames` so only these fields carry
// the dual-auth (`@aws_cognito_user_pools @aws_iam`) directive; every other admin field stays
// Cognito-only. Derived from the same mutation entries so the names never drift from the SDL.
let systemCallerFieldNames =
  apiFragmentRegistryMutationEntries
  ->Array.flatMap(e => e.fieldNames)
  ->Array.concat([Platform_ApiFragmentsApi.queryFieldName])

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
  let base = GraphQL_FragmentGenerator.generate(
    ~mutationEntries=mutationEntries(~cloner),
    ~queryEntries,
  )
  let parts = GraphQL_Stitcher.decode(base)
  // Source C subscriptions for the admin Plugin aggregate mutations.
  // The standard auto-resolver flow (CommandGeneratorResolvers_AppSync.make)
  // always creates a Subscription.onX resolver per mutation field; without the
  // matching SDL fields, AppSync's CreateResolver fails with "Type not found".
  let (pluginAggregateSubscriptionFields, pluginAggregateSubscriptionSources) =
    Plugin_SubscriptionSchema.sourceCFields(~mutationEntries=PluginBaseFragment.pluginAggregateMutationEntries)
  // The ApiFragmentRegistry aggregate's mutations go through the same CommandGenerator
  // auto-flow, which creates an `on<field>` subscription resolver per mutation. On the
  // static-push platform (AWS) those resolvers orphan unless the fields are declared in the
  // pushed baseFragment — so generate them here too, symmetric with the Plugin aggregate.
  let (apiFragmentAggregateSubscriptionFields, apiFragmentAggregateSubscriptionSources) =
    Plugin_SubscriptionSchema.sourceCFields(~mutationEntries=apiFragmentRegistryMutationEntries)
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
    ->Array.concat(pluginAggregateSubscriptionFields)
    ->Array.concat(apiFragmentAggregateSubscriptionFields),
    subscriptionSources: [uiFragmentSubscriptionSource, pluginStatusSubscriptionSource]
    ->Array.concat(pluginAggregateSubscriptionSources)
    ->Array.concat(apiFragmentAggregateSubscriptionSources),
  })
}
