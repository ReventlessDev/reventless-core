let componentType = ComponentType.ExtensionPoint

type unwrappedOutputs = {
  name: string,
  aggregateNames: array<string>,
  commandTopic: CommandTopic.unwrappedOutputs,
  eventTopic: EventTopic.unwrappedOutputs,
}
type outputs = {
  name: string,
  aggregateNames: array<string>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventTopic: Pulumi.Output.t<EventTopic.outputs>,
}
type t
type component<'operations> = Component.t<t, outputs, 'operations>

type eventHandler = (JSON.t, ReventlessSpec.Plugin.pluginDefinition) => promise<unit>

module type T = {
  type operations = {outgoingEventHandler: eventHandler}
  type component = component<operations>

  let make: (
    ~aggregateResources: dict<array<ReventlessSpec.Adapter.resource>>,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~scheduler: Scheduler.operations,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
}

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

let toUnwrappedOutputs = (outputs: outputs): Pulumi.Output.t<unwrappedOutputs> =>
  (
    outputs.commandTopic->Pulumi.Output.flatMap(CommandTopic.toUnwrappedOutputs),
    outputs.eventTopic->Pulumi.Output.flatMap(EventTopic.toUnwrappedOutputs),
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((commandTopic, eventTopic)) => {
    let unwrappedOutputs: unwrappedOutputs = {
      name: outputs.name,
      aggregateNames: outputs.aggregateNames,
      commandTopic,
      eventTopic,
    }
    unwrappedOutputs
  })
