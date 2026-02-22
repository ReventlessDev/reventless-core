let componentType = ComponentType.ExtensionPoint

type outputs = ReventlessSpec.ExtensionPoint.outputs
type t
type component<'operations> = Component.t<t, outputs, 'operations>

type eventHandler = (JSON.t, ReventlessSpec.Plugin.pluginDefinition) => promise<unit>
type operations = {outgoingEventHandler: eventHandler}

module type T = {
  type operations = operations
  type component = component<operations>

  let make: (
    ~aggregateResources: dict<array<ReventlessSpec.Adapter.resource>>,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~scheduler: Scheduler.operations,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    ~resourceNaming: ReventlessSpec.ResourceNaming.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
}

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  module type Mapping = ReventlessSpec.ExtensionPointMapping.T with module ExtensionPoint := Spec
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
