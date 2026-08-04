open ReventlessInfra.Api

@schema
type cloneArgs = {restoreDateTime?: string}

let cloneMutationEntry: mutationSchemaEntry = {
  fieldNames: [Api_Naming.adminField(~name="Clone")],
  commandSchema: cloneArgsSchema->S.castToUnknown,
  description: "Clone the system to a specific point in time",
}

// Aggregate-derived admin mutations come from `PluginBaseFragment.pluginAggregateMutationEntries`
// (Plugin aggregate) so they end up in the admin base document. The corresponding resolver wiring
// is fired in parallel by `Plugin_Helpers.registerAdminAggregateMutations` from
// `Platform_Admin.construct` over the same `~aggregates` list.
// (The ApiFragmentRegistry aggregate's entries were retired with the merged-API cutover —
// schema composition is push-free, so no deploy-time register/deregister surface exists.)
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

// Upload service (route B): mint and release object-store uploads through the GraphQL
// API instead of an anonymous Function URL, so AppSync's Cognito authorizer
// authenticates the caller and the verified identity reaches the resolver. `store` is
// the qualified `{plugin}.{store}` the caller declares; the resolver Lambda maps it to
// a bucket/prefix. No subscription source — these are request/response operations, not
// Source-C event fan-ins.
//
// These constants live here (next to the other cross-provider platform SDL constants)
// but are deliberately NOT part of `baseFragment`: the admin base is Admin-group gated
// (`injectAwsAuthAll(~group="Admin")`), and uploads are a regular authenticated-user
// operation. They are added instead to the **domain** API's platform-owned base
// (`domainBaseFragment` in the AWS/local Platform), which takes the default
// `AllowAuthenticated` auth. See [docs/plans/done/upload-release-path.md] § "Which API".
let uploadTypes = [
  `type Upload_Ticket {\n  uploadUrl: String!\n  storageRef: String!\n}`,
  `type Upload_ReleaseResult {\n  released: Boolean!\n  reason: String\n}`,
]

let uploadMutationFields = [
  `  Upload_Presign(store: ID!, fileName: String!, contentType: String): Upload_Ticket`,
  `  Upload_Release(store: ID!, storageRef: String!): Upload_ReleaseResult`,
]

// Geocoding service (D9 half 2): turn an address into ranked coordinate candidates
// through the platform GraphQL API instead of an anonymous Function URL, so
// AppSync's Cognito authorizer authenticates the caller. Geocoding is a *read*, so
// a Query field. Like the upload fields these belong on the **domain** base
// (`domainBaseFragment` in the AWS/local Platform), which takes the default
// `AllowAuthenticated` auth — not the Admin-gated admin base, and so deliberately
// NOT part of `baseFragment` below.
//
// This is the client door of the geocoding capability; plugin backend code reaches
// the same place index through an injected port (`Reventless.Capabilities.geocode`,
// backed by `Geocoder_AwsLocation_Backend`). One capability, two doors — mirroring
// the object store's `Upload_Presign` / `Offload.resolve` split. `relevance` is
// nullable because a provider that does not score its results returns none.
let geocodeTypes = [
  `type GeocodeCandidate {\n  label: String!\n  lat: Float!\n  lng: Float!\n  relevance: Float\n}`,
]

let geocodeQueryFields = [`  geocode(text: String!): [GeocodeCandidate!]`]

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
  GraphQL_Stitcher.encode({
    types: parts.types
    ->Array.concat(uiFragmentSubscriptionTypes)
    ->Array.concat(pluginStatusSubscriptionTypes)
    ->Array.concat(Platform_ComponentDefinitionsApi.sdlTypes)
    ->Array.concat(Platform_PluginStructuresApi.sdlTypes)
    ->Array.concat(Platform_UIFragmentsApi.sdlTypes),
    queries: Array.concat(
      parts.queries,
      [
        Platform_ComponentDefinitionsApi.sdlQueryField,
        Platform_PluginStructuresApi.sdlQueryField,
        Platform_UIFragmentsApi.sdlQueryField,
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
