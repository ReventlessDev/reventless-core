@schema
type name = string
@schema
type version = string

@schema
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
}

@schema
type extensionDefinition = {
  name: string,
  extensionPointName: string,
}

// Protocol version declaration for a single extension point connection.
// Carried in the ConnectPlugin handshake so the host can validate compatibility.
@schema
type extensionProtocol = {
  extensionPointName: string,
  commandVersion: string, // SemVer of the command schema the extension was compiled with
  eventVersion: string, // SemVer of the event schema the extension was compiled with
}

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
  resolvers: Pulumi.Output.t<array<Adapter.resource>>,
  heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
  stateViewSlices: Pulumi.Output.t<dict<StateViewSlice.outputs>>,
}

module type DcbSpec = {
  @schema
  type event
  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
  let stateViewSlices: array<module(StateViewSlice.T with type dcbEvent = event)>
}

module type T = {
  type api
  type role
  type component
  let make: (
    ~name: string,
    ~version: string,
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
