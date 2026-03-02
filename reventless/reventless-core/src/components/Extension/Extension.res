let componentType = ComponentType.Extension

type outputs = ReventlessInfra.Extension.outputs
type t

type jsonEventsHandler = (JSON.t, Reventless.Plugin.pluginDefinition) => promise<unit>
type operations = {incomingJsonEventsHandler: jsonEventsHandler, outgoingJsonEventsHandler: jsonEventsHandler}
type component = Component.t<t, outputs, operations>

module type T = {
  type operations = operations
  type component = component

  let make: (
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: dict<array<string>>,
    ~publishToReadModels: dict<EventCollector.enqueueEvent>,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
}

module type Mappings = {
  module Spec: ReventlessInfra.ExtensionMapping.Spec
  module type Mapping = ReventlessInfra.ExtensionMapping.T with module ExtensionPoint := Spec
  let name: string
  let mappings: array<module(Mapping)>
}
