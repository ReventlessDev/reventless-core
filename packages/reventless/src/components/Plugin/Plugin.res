let componentType = ComponentType.Plugin

type outputs = {
  id: Pulumi.Output.t<string>,
  version: Pulumi.Output.t<string>,
  heartbeatInterval: Pulumi.Output.t<int>,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  extensionPoints: Pulumi.Output.t<Js.Dict.t<ExtensionPoint.outputs>>,
  extensions: Pulumi.Output.t<Js.Dict.t<Extension.outputs>>,
  aggregates: Pulumi.Output.t<Js.Dict.t<Aggregate.outputs>>,
  readModels: Pulumi.Output.t<Js.Dict.t<ReadModel.outputs>>,
  tasks: Pulumi.Output.t<Js.Dict.t<Task.outputs>>,
  resolvers: Pulumi.Output.t<array<ReventlessSpec.Adapter.resource>>,
  heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~taskMakers: array<Task.maker>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
