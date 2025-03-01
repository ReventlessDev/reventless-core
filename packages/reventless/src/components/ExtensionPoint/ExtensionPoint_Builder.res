module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: ExtensionPoint.Mappings with module Spec := Spec,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
  EventTopicAdapter: EventTopic_Adapter.Publisher,
  RuntimeEnvironment: Runtime.Environment,
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

  let construct = (
    ~publishToAggregates,
    ~scheduler: Scheduler.operations,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->Js.String2.replace(".", "")->ComponentType.name(ExtensionPoint.componentType)

    module SpecificCommandTopic = CommandTopic_Builder.Make(SpecWithId, CommandTopicChannel)
    let commandTopicChannel = SpecificCommandTopic.makeChannel(~name, ~opts)

    let (commandTopic, eventTopic, outgoingEventHandler) =
      commandTopicChannel.resources
      ->Adapter.resourcesToUnwrappedOutput
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
          ~channel=commandTopicChannel,
          ~commandsHandler=ExtensionPointCallback.handleIncomingCommands,
        )
        let runtime = RuntimeEnvironment.make(~name, ~handler, ~opts)

        let commandTopic = SpecificCommandTopic.make(
          ~name,
          ~channel=commandTopicChannel,
          ~runtime,
          ~opts,
        )

        module SpecificEventTopic = EventTopic_Builder.Make(SpecWithId, EventTopicAdapter)
        let eventTopic = SpecificEventTopic.make(~name, ~storageResources=[], ~opts)

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
      aggregateNames: Mappings.mappings->Belt.Array.keepMap((module(Mapping)) =>
        Mapping.mapOutgoingEvent->Belt.Option.map(_ => Mapping.aggregateName)
      ),
      commandTopic: commandTopic->Pulumi.Output.apply(commandTopic =>
        commandTopic->Component.outputs
      ),
      eventTopic: eventTopic->Pulumi.Output.apply(eventTopic => eventTopic->Component.outputs),
    })
  }

  let make = (~publishToAggregates, ~scheduler, ~queryEngine, ~opts) =>
    Component.make(
      ~componentType=ExtensionPoint.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~publishToAggregates, ~scheduler, ~queryEngine, ...),
      ~opts
    )
}
