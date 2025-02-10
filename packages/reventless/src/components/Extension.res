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
    ~publishToCorePluginExtensionPoint: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: Js.Dict.t<array<string>>,
    ~publishToReadModels: Js.Dict.t<ReventlessSpec.EventCollector.enqueueEvent>,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
}

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionMapping.Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name: string
  let mappings: array<module(Mapping)>
}

module Make = (
  Spec: ReventlessSpec.ExtensionMapping.Spec,
  Mappings: Mappings with module Spec := Spec,
): T => {
  type operations = {incomingEventHandler: eventHandler, outgoingEventHandler: eventHandler}
  type component = Component.t<t, outputs, operations>

  let construct = (
    ~publishToCorePluginExtensionPoint: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: Js.Dict.t<array<string>>,
    ~publishToReadModels: Js.Dict.t<ReventlessSpec.EventCollector.enqueueEvent>,
    ~queryEngine,
    self,
    name,
  ) => {
    let eventHandlers =
      publishToCorePluginExtensionPoint->Pulumi.Output.apply(publishToCorePluginExtensionPoint => {
        module RuntimeSpec = {
          let publishToAggregates = publishToAggregates
          let publishToCorePluginExtensionPoint = publishToCorePluginExtensionPoint
          let readModelNamesForSourceName = readModelNamesForSourceName
          let publishToReadModels = publishToReadModels
          let queryEngine = queryEngine
        }
        module Runtime = Extension_Runtime.Make(RuntimeSpec, Spec, Mappings)

        {
          incomingEventHandler: Runtime.incomingEventHandler,
          outgoingEventHandler: Runtime.outgoingEventHandler,
        }
      })

    self->Component.setOperations(eventHandlers)
    self->Component.setOutputs({
      name,
      extensionPointName: Spec.name,
      aggregateNames: Mappings.mappings->Belt.Array.keepMap((module(Mapping)) =>
        Mapping.aggregateName == ReventlessSpec.ExtensionMapping.NoAggregate.name ||
          Mapping.mapOutgoingEvent->Belt.Option.isNone
          ? None
          : Some(Mapping.aggregateName)
      ),
    })
  }

  let make = (
    ~publishToCorePluginExtensionPoint,
    ~publishToAggregates,
    ~readModelNamesForSourceName,
    ~publishToReadModels,
    ~queryEngine,
    ~opts,
  ) =>
    Component.make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name ++ ("." ++ Mappings.name),
      ~construct=construct(
        ~publishToCorePluginExtensionPoint,
        ~publishToAggregates,
        ~readModelNamesForSourceName,
        ~publishToReadModels,
        ~queryEngine,
        ...
      ),
      ~opts,
    )
}
