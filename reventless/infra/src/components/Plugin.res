/**
Deploy-time outputs produced by the `Plugin.T.make` function.

All fields are `Pulumi.Output.t`-wrapped because they reference resources
provisioned during the Pulumi stack update.
*/
type outputs = {
  id: Pulumi.Output.t<string>,
  version: Pulumi.Output.t<string>,
  heartbeatInterval: Pulumi.Output.t<int>,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  extensionPoints: Pulumi.Output.t<dict<ExtensionPoint.outputs>>,
  extensions: Pulumi.Output.t<dict<Extension.outputs>>,
  aggregates: Pulumi.Output.t<dict<Aggregate.outputs>>,
  readModels: Pulumi.Output.t<dict<ReadModel.outputs>>,
  tasks: Pulumi.Output.t<dict<Task.outputs>>,
  /** AppSync / GraphQL resolver resources. */
  resolvers: Pulumi.Output.t<array<Adapter.resource>>,
  heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
  apiSchemaFragment: Pulumi.Output.t<option<Reventless.Plugin.apiSchemaFragment>>,
  /** UI fragment manifest for runtime micro-frontend registration (None for pure backend plugins). */
  uiFragments: Pulumi.Output.t<option<Reventless.Plugin.uiFragmentManifest>>,
  /** Plugin structure carrying queryable and writable component metadata (None for pure backend plugins). */
  pluginStructure: Pulumi.Output.t<option<Reventless.Plugin.pluginStructure>>,
  /** Present when the plugin uses a `DcbEventLog`. */
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
  stateViewSlices: Pulumi.Output.t<dict<StateViewSlice.outputs>>,
  automationSlices: Pulumi.Output.t<dict<AutomationSlice.outputs>>,
  outboundTranslationSlices: Pulumi.Output.t<dict<OutboundTranslationSlice.outputs>>,
  inboundTranslationSlices: Pulumi.Output.t<dict<InboundTranslationSlice.outputs>>,
}

/**
Module type for the top-level plugin factory.

Call `Plugin.T.make` to provision all plugin components (aggregates, read models,
tasks, extension points, extensions, heartbeat, DCB log) in a single Pulumi stack update.

DCB slices are passed directly as optional labeled arrays. When any slice array
is non-empty, a shared DCB EventLog is provisioned automatically.
*/
module type T = {
  type api
  type role
  type component
  let make: (
    ~name: string,
    /** How often (in seconds) the heartbeat Lambda fires. */
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ExtensionPoint.T)>=?,
    ~extensions: array<module(Extension.Blueprint)>=?,
    ~aggregates: array<module(Aggregate.T with type api = api)>=?,
    ~readModels: array<module(ReadModel.T with type api = api and type role = role)>=?,
    ~tasks: array<module(Task.T)>=?,
    ~stateChangeSlices: array<module(StateChangeSlice.T)>=?,
    ~stateViewSlices: array<module(StateViewSlice.T)>=?,
    ~automationSlices: array<module(AutomationSlice.T)>=?,
    ~outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>=?,
    ~inboundTranslationSlices: array<module(InboundTranslationSlice.T)>=?,
    /** Spec names of StateChangeSlices / StateViewSlices whose GraphQL fields a
        deploy-time system caller (SigV4 / IAM) must invoke. Sets
        `systemCallable: true` on the matching mutation / query schema entries so
        the AWS provider emits the dual-auth
        `@aws_cognito_user_pools(...) @aws_iam` directive form. Authored via
        `@@reventless.systemCallable` on the spec file and threaded here by the
        plugin generator; see `docs/guides/appsync-iam-system-caller.md`. */
    ~systemCallableComponents: array<string>=?,
    /** Per-component runtime resource hints keyed by component name, authored in
        the plugin's `plugin.json` `runtime` block and emitted by the plugin
        generator. The deploy loop looks up each component's hint by `Spec.name`
        and forwards it into that component's `make`. See
        docs/plans/configurable-component-runtime-resources.md. */
    ~componentRuntime: dict<RuntimeHints.t>=?,
    ~uiFragments: Reventless.Plugin.uiFragmentManifest=?,
    ~pluginStructure: Reventless.Plugin.pluginStructure=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let makeAutoUIManifest: (
    ~remoteEntryUrl: string,
    ~name: string,
    ~pluginStructure: Reventless.Plugin.pluginStructure,
    ~readModelPositions: array<string>=?,
    ~aggregatePositions: array<string>=?,
  ) => Reventless.Plugin.uiFragmentManifest
  let makePluginDefinition: (
    ~name: string,
    ~aggregates: array<module(Aggregate.T with type api = api)>=?,
    ~readModels: array<module(ReadModel.T with type api = api and type role = role)>=?,
    ~stateViewSlices: array<module(StateViewSlice.T)>=?,
    ~stateChangeSlices: array<module(StateChangeSlice.T)>=?,
    ~automationSlices: array<module(AutomationSlice.T)>=?,
    ~outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>=?,
    ~inboundTranslationSlices: array<module(InboundTranslationSlice.T)>=?,
    ~extensions: array<module(Extension.Blueprint)>=?,
    ~extensionPoints: array<module(ExtensionPointMapping.Mapping)>=?,
    ~componentChapters: dict<string>=?,
  ) => Reventless.Plugin.pluginStructure
}
