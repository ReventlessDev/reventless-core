module Make = (
  Spec: ReventlessInfra.ExtensionMapping.Spec,
  Mappings: Extension.Mappings with module Spec := Spec,
): Extension.T => {
  type operations = Extension.operations
  type component = Extension.component

  let construct = (
    ~publishToPluginExtensionPoint: CommandTopic.publishJsons,
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
        let publishToPluginExtensionPoint = publishToPluginExtensionPoint
        let readModelNamesForSourceName = readModelNamesForSourceName
        let publishToReadModels = publishToReadModels
        let queryEngine = queryEngine
      },
    )
    let operations: Extension.operations = {
      incomingJsonEventsHandler: Operations.incomingJsonEventsHandler,
      outgoingJsonEventsHandler: Operations.outgoingJsonEventsHandler,
    }

    self->Component.setOperations(operations->Pulumi.Output.make)
    let extOutputs: Extension.outputs = {
      name,
      extensionPointName: Spec.name,
      aggregateNames: Mappings.mappings->Array.filterMap((module(Mapping)) =>
        Mapping.delegateName == ReventlessInfra.ExtensionMapping.NoDelegate.name ||
          Mapping.mapOutgoingEvent->Option.isNone
          ? None
          : Some(Mapping.delegateName)
      ),
    }
    self->Component.setOutputs(extOutputs)
  }

  let make = (
    ~publishToPluginExtensionPoint,
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
        ~publishToPluginExtensionPoint,
        ~publishToAggregates,
        ~readModelNamesForSourceName,
        ~publishToReadModels,
        ~queryEngine,
        ...
      ),
      ~opts,
    )

  let outputs = Component.outputs
  let operations = Component.operations
}
