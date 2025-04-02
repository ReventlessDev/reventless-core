module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: ExtensionPoint.Mappings with module Spec := Spec,
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
): ExtensionPoint.T => {
  module Spec = Spec

  type operations = {outgoingEventHandler: ExtensionPoint.eventHandler}
  type component = Component.t<ExtensionPoint.t, ExtensionPoint.outputs, operations>

  module SpecWithId: ReventlessSpec.ExtensionPoint.Spec
    with type command = Spec.command
    and type event = Spec.event
    and type callCommand = Spec.callCommand = {
    include Spec
    module Id = ReventlessSpec.Id.String
  }

  let filterAggregateResources = (aggregateResources, aggregateNames) =>
    aggregateResources
    ->Js.Dict.entries
    ->Belt.Array.keep(((name, _)) =>
      aggregateNames->Belt.Array.some(aggregateName => aggregateName == name)
    )
    ->Array.map(((_, resources)) => resources)
    ->Array.flat

  let construct = (
    ~aggregateResources,
    ~publishToAggregates,
    ~scheduler: Scheduler.operations,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let childName =
      name->Js.String2.replace(".", "")->ComponentType.name(ExtensionPoint.componentType)

    module SpecificCommandTopic = CommandTopic_Builder.Make(SpecWithId, CommandTopicChannel)
    let commandTopic = SpecificCommandTopic.make(~name=childName, ~opts)
    let commandTopicOpts = {
      Pulumi.ComponentResource.parent: commandTopic->Component.toPulumiResource,
    }

    let aggregateNames =
      Mappings.mappings->Belt.Array.keepMap((module(Mapping)) =>
        Mapping.mapOutgoingEvent->Belt.Option.map(_ => Mapping.aggregateName)
      )

    let commandTopicResources =
      (commandTopic->CommandTopic_Adapter.channel).resources->Adapter.resourcesToUnwrappedOutput

    let (commandTopic, eventTopic, outgoingEventHandler) =
      commandTopicResources
      ->Pulumi.Output.flatMap(commandTopicResources => {
        module ExtensionPointCallback = ExtensionPoint_Callback.Make(
          {
            let publishToAggregates = publishToAggregates
            let commandTopicResources = commandTopicResources
            let scheduler = scheduler
            let queryEngine = queryEngine
          },
          Spec,
          Mappings,
        )
        let handler = SpecificCommandTopic.makeHandler(
          ~commandTopic,
          ~commandsHandler=ExtensionPointCallback.handleIncomingCommands,
        )
        let runtime = RuntimeEnvironment.make(~name=childName, ~handler, ~opts=commandTopicOpts)

        SpecificCommandTopic.connect(
          ~name=childName,
          ~commandTopic,
          ~runtime,
          ~resources=aggregateResources->filterAggregateResources(aggregateNames),
          ~opts=commandTopicOpts,
        )

        module SpecificEventTopic = EventTopic_Builder.Make(SpecWithId, EventTopicAdapter)
        let eventTopic = SpecificEventTopic.make(~name=childName, ~storageResources=[], ~opts)

        eventTopic
        ->Component.operations
        ->Pulumi.Output.apply(({publishJson: publishToEventTopic}) => {
          module OperationsSpec = {
            let publishToEventTopic = publishToEventTopic
            let commandTopicResources = commandTopicResources
            let scheduler = scheduler
            let queryEngine = queryEngine
          }
          module Operations = ExtensionPoint_Operations.Make(OperationsSpec, Spec, Mappings)

          (commandTopic, eventTopic, Operations.outgoingEventHandler)
        })
      })
      ->Pulumi.Output.unzip3

    self->Component.setOperations(
      outgoingEventHandler->Pulumi.Output.apply(outgoingEventHandler => {
        outgoingEventHandler: outgoingEventHandler,
      }),
    )

    self->Component.setOutputs({
      ExtensionPoint.name,
      aggregateNames,
      commandTopic: commandTopic->Pulumi.Output.apply(commandTopic =>
        commandTopic->Component.outputs
      ),
      eventTopic: eventTopic->Pulumi.Output.apply(eventTopic => eventTopic->Component.outputs),
    })
  }

  let make = (~aggregateResources, ~publishToAggregates, ~scheduler, ~queryEngine, ~opts) =>
    Component.make(
      ~componentType=ExtensionPoint.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(
        ~aggregateResources,
        ~publishToAggregates,
        ~scheduler,
        ~queryEngine,
        ...
      ),
      ~opts
    )
}
