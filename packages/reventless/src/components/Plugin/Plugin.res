let componentType = ComponentType.Plugin

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
  resolvers: Pulumi.Output.t<array<ReventlessSpec.Adapter.resource>>,
  heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
  dcbEventLog: Pulumi.Output.t<option<DcbEventLog.outputs>>,
  stateChangeSlices: Pulumi.Output.t<dict<StateChangeSlice.outputs>>,
}

type t
type component = Component.t<t, outputs, unit>

// DCB spec for plugin-wide event/command types and state change slices
// Bundled together so the event type is shared between the DcbEventLog and all StateChangeSlices
module type DcbSpec = {
  @schema
  type event

  @schema
  type command

  let stateChangeSlices: array<module(StateChangeSlice.T with type dcbEvent = event)>
}

module type T = {
  let make: (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ExtensionPoint.T)>=?,
    ~extensions: array<module(Extension.T)>=?,
    ~aggregates: array<module(Aggregate.T)>=?,
    ~readModels: array<module(ReadModel.T)>=?,
    ~tasks: array<module(Task.T)>=?,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~dcbSpec: module(DcbSpec)=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let makeId = (name, version) => `${name}@${version}`
