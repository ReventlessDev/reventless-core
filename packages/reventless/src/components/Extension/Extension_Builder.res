module Make = (
  Spec: ReventlessSpec.ExtensionMapping.Spec,
  Mappings: Extension.Mappings with module Spec := Spec,
): Extension.T => {
  type operations = {
    incomingEventHandler: Extension.eventHandler,
    outgoingEventHandler: Extension.eventHandler,
  }
  type component = Component.t<Extension.t, Extension.outputs, operations>

  let construct = (
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
    ~publishToAggregates: Js.Dict.t<CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: Js.Dict.t<array<string>>,
    ~publishToReadModels: Js.Dict.t<EventCollector.enqueueEvent>,
    ~queryEngine,
    self,
    name,
  ) => {
    module Operations = Extension_Operations.Make(
      {
        let publishToAggregates = publishToAggregates
        let publishToCorePluginExtensionPoint = publishToCorePluginExtensionPoint
        let readModelNamesForSourceName = readModelNamesForSourceName
        let publishToReadModels = publishToReadModels
        let queryEngine = queryEngine
      },
      Spec,
      Mappings,
    )
    let operations = {
      {
        incomingEventHandler: Operations.incomingEventHandler,
        outgoingEventHandler: Operations.outgoingEventHandler,
      }
    }

    self->Component.setOperations(operations->Pulumi.Output.make)
    self->Component.setOutputs({
      Extension.name,
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
      ~componentType=Extension.componentType->ComponentType.toString,
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
