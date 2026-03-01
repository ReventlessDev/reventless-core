module Make = (
  Spec: Reventless.ExtensionPointMapping.Spec,
  Mappings: ExtensionPoint.Mappings with module Spec := Spec,
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
  ExtensionPointRuntimeBuilder: ExtensionPointRuntime_Builder.T
    with module CommandTopicChannel := CommandTopicChannel,
): ExtensionPoint.T => {
  module Spec = Spec

  type operations = ExtensionPoint.operations
  type component = ExtensionPoint.component<operations>

  module SpecWithId: Reventless.ExtensionPoint.Spec
    with type command = Spec.command
    and type event = Spec.event
    and type directive = Spec.directive = {
    include Spec
    module Id = Reventless.Id.String
  }

  let filterAggregateResources = (aggregateResources, aggregateNames) =>
    aggregateResources
    ->Dict.toArray
    ->Array.filter(((name, _)) =>
      aggregateNames->Belt.Array.some(aggregateName => aggregateName == name)
    )
    ->Array.map(((_, resources)) => resources)
    ->Array.flat

  let construct = (
    ~aggregateResources,
    ~publishToAggregates,
    ~scheduler: Scheduler.operations,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~resourceNaming: Reventless.ResourceNaming.operations,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let childName = name->String.replace(".", "")->ComponentType.name(ExtensionPoint.componentType)

    module SpecificCommandTopic = CommandTopic_Builder.Make(SpecWithId, CommandTopicChannel)
    let commandTopic = SpecificCommandTopic.make(~name=childName, ~opts)

    let aggregateNames =
      Mappings.mappings->Array.filterMap((module(Mapping)) =>
        Mapping.mapOutgoingEvent->Option.map(_ => Mapping.aggregateName)
      )

    let commandTopicResources =
      (commandTopic->CommandTopic_Adapter.channel).resources->Adapter.resourcesToResolvedOutput

    let (commandTopic, eventTopic, outgoingJsonEventsHandler) =
      commandTopicResources
      ->Pulumi.Output.flatMap(commandTopicResources => {
        module ExtensionPointCallback = ExtensionPoint_Callback.Make(
          {
            let publishToAggregates = publishToAggregates
            let commandTopicResources = commandTopicResources
            let scheduler = scheduler
            let queryEngine = queryEngine
            let resourceNaming = resourceNaming
          },
          Spec,
          Mappings,
        )
        let handler = SpecificCommandTopic.makeHandler(
          ~commandTopic,
          ~commandsHandler=ExtensionPointCallback.handleIncomingCommands,
        )
        let resources = aggregateResources->filterAggregateResources(aggregateNames)

        commandTopic->ExtensionPointRuntimeBuilder.forCommandTopic(
          ~handler,
          ~connect=SpecificCommandTopic.connect(commandTopic, ~resources, ...),
        )

        module SpecificEventTopic = EventTopic_Builder.Make(SpecWithId, EventTopicAdapter)
        let eventTopic = SpecificEventTopic.make(~name=childName, ~storageResources=[], ~opts)

        eventTopic
        ->Component.operations
        ->Pulumi.Output.apply(({publishJson: publishToEventTopic}) => {
          module Ops = ExtensionPoint_Operations.Make(
            Spec,
            Mappings,
            {
              let publishToEventTopic = publishToEventTopic
              let commandTopicResources = commandTopicResources
              let scheduler = scheduler
              let queryEngine = queryEngine
              let resourceNaming = resourceNaming
            },
          )

          (commandTopic, eventTopic, Ops.outgoingJsonEventsHandler)
        })
      })
      ->Pulumi.Output.unzip3

    self->Component.setOperations(
      outgoingJsonEventsHandler->Pulumi.Output.apply(outgoingJsonEventsHandler =>
        ({outgoingJsonEventsHandler: outgoingJsonEventsHandler}: ExtensionPoint.operations)
      ),
    )

    let epOutputs: ExtensionPoint.outputs = {
      name,
      aggregateNames,
      commandTopic: commandTopic->Pulumi.Output.apply(commandTopic =>
        commandTopic->Component.outputs
      ),
      eventTopic: eventTopic->Pulumi.Output.apply(eventTopic => eventTopic->Component.outputs),
    }
    self->Component.setOutputs(epOutputs)
  }

  let make = (
    ~aggregateResources,
    ~publishToAggregates,
    ~scheduler,
    ~queryEngine,
    ~resourceNaming,
    ~opts,
  ) =>
    Component.make(
      ~componentType=ExtensionPoint.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(
        ~aggregateResources,
        ~publishToAggregates,
        ~scheduler,
        ~queryEngine,
        ~resourceNaming,
        ...
      ),
      ~opts,
    )

  let outputs = Component.outputs
}
