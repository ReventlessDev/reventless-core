let componentType = ComponentType.Extension

type outputs = {
  name: string,
  extensionPointName: string,
  aggregateNames: array<string>,
}
type t

type eventHandler = (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>

module type T = {
  type operations = {incomingEventHandler: eventHandler, outgoingEventHandler: eventHandler}
  type component = Component.t<t, outputs, operations>

  let make: (
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
    ~publishToAggregates: Js.Dict.t<CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: Js.Dict.t<array<string>>,
    ~publishToReadModels: Js.Dict.t<EventCollector.enqueueEvent>,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
}

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionMapping.Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name: string
  let mappings: array<module(Mapping)>
}
