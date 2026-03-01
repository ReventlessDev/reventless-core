/** The logical name of a plugin (serializable as JSON). */
@schema
type name = string

/** The semantic version string of a plugin release. */
@schema
type version = string

/**
Describes an extension point exported by a plugin.
Included in the plugin's `pluginDefinition` for use by the gateway / host.
*/
@schema
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
}

/**
Describes an extension imported by a plugin (i.e. a connection to a host plugin's
extension point).
Included in the plugin's `pluginDefinition` for use by the host.
*/
@schema
type extensionDefinition = {
  name: string,
  extensionPointName: string,
}

/**
Protocol version declaration for a single extension point connection.

Carried in the `ConnectPlugin` handshake so the host can validate schema
compatibility before accepting the extension. Use `[]` when version
negotiation is not needed.
*/
// Protocol version declaration for a single extension point connection.
// Carried in the ConnectPlugin handshake so the host can validate compatibility.
@schema
type extensionProtocol = {
  extensionPointName: string,
  /** SemVer of the command schema the extension was compiled against. */
  commandVersion: string,
  /** SemVer of the event schema the extension was compiled against. */
  eventVersion: string,
}

/**
The self-description of a deployed plugin, persisted in the plugin's event store.

Used by the gateway to discover extension points, extensions, and protocol versions.
The `eventCollector` field is mutable so it can be set after the heartbeat lambda
registers its own ARN.
*/
@schema
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,
  // Protocol version declarations for each extension point this plugin connects to.
  // Use [] when the plugin does not need version negotiation.
  extensionProtocols: array<extensionProtocol>,
}

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
  /** Present when the plugin uses a `DcbEventLog`. */
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
  stateViewSlices: Pulumi.Output.t<dict<StateViewSlice.outputs>>,
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
}
```
*/
module type DcbSpec = {
  /** The shared event type for all slices in this plugin. Must carry `@schema`. */
  @schema
  type event
  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
  let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
}

/**
Module type for the top-level plugin factory.

Call `Plugin.T.make` to provision all plugin components (aggregates, read models,
tasks, extension points, extensions, heartbeat, DCB log) in a single Pulumi stack update.

@example
```rescript
// Aggregate-based catalog
let plugin = CatalogPlugin.make(
  ~name="Catalog",
  ~version="1.0.0",
  ~heartbeatInterval=60,
  ~aggregates=[module(CategoryAggregate), module(ProductAggregate)],
  ~readModels=[module(CategoryReadModel), module(ProductReadModel)],
  ~api,
  ~apiRole,
  ~scheduler,
)

// DCB-based catalog
let plugin = CatalogPlugin.make(
  ~name="Catalog",
  ~version="1.0.0",
  ~heartbeatInterval=60,
  ~api,
  ~apiRole,
  ~scheduler,
  ~dcbSpec=module(DcbSpec),
)
```
*/
module type T = {
  type api
  type role
  type component
  let make: (
    ~name: string,
    ~version: string,
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
