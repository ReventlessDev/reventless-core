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
  /** Present when the plugin uses a `DcbEventLog`. */
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
  stateViewSlices: Pulumi.Output.t<dict<StateViewSlice.outputs>>,
  automationSlices: Pulumi.Output.t<dict<AutomationSlice.outputs>>,
  outboundTranslationSlices: Pulumi.Output.t<dict<OutboundTranslationSlice.outputs>>,
  inboundTranslationSlices: Pulumi.Output.t<dict<InboundTranslationSlice.outputs>>,
}

/**
The DCB (Distributed Command Behavior) specification for a plugin.

Groups all state change and state view slices under a shared event log.
Pass this as `~dcbSpec` to `Plugin.T.make` when the plugin uses DCB components.

@example
```rescript
// CatalogPlugin.res (DCB variant)
module DcbSpec = {
  @schema type event = CatalogEventLog.event
  let stateChangeSlices = [
    module(AddCategorySlice),
    module(RenameCategorySlice),
    module(ArchiveCategorySlice),
    module(AddProductSlice),
    module(UpdateProductNameSlice),
  ]
  let stateViewSlices = [module(CategoriesViewSlice), module(ProductsViewSlice)]
  let automationSlices = []
  let outboundTranslationSlices = []
  let inboundTranslationSlices = []
}
```
*/
module type DcbSpec = {
  /** The shared event type for all slices in this plugin. Must carry `@schema`. */
  @schema
  type event
  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
  let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
  let automationSlices: array<module(AutomationSlice.T with type dcbEvent = event)>
  let outboundTranslationSlices: array<module(OutboundTranslationSlice.T with type dcbEvent = event)>
  let inboundTranslationSlices: array<module(InboundTranslationSlice.T with type dcbEvent = event)>
}

/**
Module type for the top-level plugin factory.

Call `Plugin.T.make` to provision all plugin components (aggregates, read models,
tasks, extension points, extensions, heartbeat, DCB log) in a single Pulumi stack update.
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
    ~extensions: array<module(Extension.T)>=?,
    ~aggregates: array<module(Aggregate.T with type api = api)>=?,
    ~readModels: array<module(ReadModel.T with type api = api and type role = role)>=?,
    ~tasks: array<module(Task.T)>=?,
    ~api: api,
    ~apiRole: role,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~dcbSpec: module(DcbSpec)=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
