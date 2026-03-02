let componentType = ComponentType.Core

type outputs = {
  version: string,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  extensionPoints: Pulumi.Output.t<dict<ExtensionPoint.outputs>>,
  aggregates: Pulumi.Output.t<dict<Aggregate.outputs>>,
  readModels: dict<ReadModel.outputs>,
  cloner: Cloner.outputs,
  api?: ReventlessInfra.Api.component,
}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~version: string,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
  ) => component
}
