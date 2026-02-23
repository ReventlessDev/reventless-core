module Make = (
  Spec: ReventlessSpec.ExtensionMapping.Spec,
  Mappings: Extension.Mappings with module Spec := Spec,
): Extension.T => {
  type operations = Extension.operations
  type component = Extension.component

  let construct = (
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: dict<array<string>>,
    ~publishToReadModels: dict<EventCollector.enqueueEvent>,
    ~queryEngine,
    self,
    name,
  ) => {
    module Operations = Extension_Operations.Make(
      Spec,
      Mappings,
      {
        let publishToAggregates = publishToAggregates
        let publishToCorePluginExtensionPoint = publishToCorePluginExtensionPoint
        let readModelNamesForSourceName = readModelNamesForSourceName
        let publishToReadModels = publishToReadModels
        let queryEngine = queryEngine
      },
    )
    let operations: Extension.operations = {
      incomingEventHandler: Operations.incomingEventHandler,
      outgoingEventHandler: Operations.outgoingEventHandler,
    }

    self->Component.setOperations(operations->Pulumi.Output.make)
    let extOutputs: Extension.outputs = {
      name,
      extensionPointName: Spec.name,
      aggregateNames: Mappings.mappings->Array.filterMap((module(Mapping)) =>
        Mapping.aggregateName == ReventlessSpec.ExtensionMapping.NoAggregate.name ||
          Mapping.mapOutgoingEvent->Option.isNone
          ? None
          : Some(Mapping.aggregateName)
      ),
    }
    self->Component.setOutputs(extOutputs)
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

  let outputs = Component.outputs
}
