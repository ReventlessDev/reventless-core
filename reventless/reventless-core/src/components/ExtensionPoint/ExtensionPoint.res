let componentType = ComponentType.ExtensionPoint

type outputs = ReventlessInfra.ExtensionPoint.outputs
type t
type component<'operations> = Component.t<t, outputs, 'operations>

type jsonEventsHandler = (JSON.t, Reventless.Plugin.pluginDefinition) => promise<unit>
type operations = {outgoingJsonEventsHandler: jsonEventsHandler}

module type T = {
  type operations = operations
  type component = component<operations>

  let make: (
    ~aggregateResources: dict<array<ReventlessInfra.Adapter.resource>>,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~scheduler: Scheduler.operations,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
}

module type Mappings = {
  module Spec: ReventlessInfra.ExtensionPointMapping.Spec
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.ExtensionPoint.resolvedOutputs> =>
  (
    outputs.commandTopic->Pulumi.Output.flatMap(CommandTopic.toResolvedOutputs),
    outputs.eventTopic->Pulumi.Output.flatMap(EventTopic.toResolvedOutputs),
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((commandTopic, eventTopic)) => {
    let resolved: ReventlessInterop.ExtensionPoint.resolvedOutputs = {
      name: outputs.name,
      commandTopic,
      eventTopic,
    }
    resolved
  })
