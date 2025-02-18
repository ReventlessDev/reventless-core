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
type t

type eventHandler = (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>

module type T = {
  type operations = {outgoingEventHandler: eventHandler}
  type component = Component.t<t, outputs, operations>

  let make: (
    ~publishToAggregates: Js.Dict.t<CommandTopic.publishJsons>,
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

module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := Spec,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
  EventTopicAdapter: EventTopic.Adapter.Publisher,
  RuntimeEnvironment: Runtime.Environment,
): T => {
  module Spec = Spec

  type operations = {outgoingEventHandler: eventHandler}
  type component = Component.t<t, outputs, operations>

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

    let childName = name->Js.String2.replace(".", "")->ComponentType.name(componentType)

    module SpecificCommandTopic = CommandTopic_Builder.Make(
      SpecWithId,
      CommandTopicChannel,
      RuntimeEnvironment,
    )
    let commandTopicChannel = SpecificCommandTopic.makeChannel(~name=childName, ~opts)

    let (commandTopic, eventTopic, outgoingEventHandler) =
      commandTopicChannel.resources
      ->Adapter.resourcesToUnwrappedOutput
      ->Pulumi.Output.flatMap(commandTopicResources => {
        module CallbackSpec = {
          let publishToAggregates = publishToAggregates
          let commandTopicResources = commandTopicResources
          let scheduler = scheduler
          let queryEngine = queryEngine
        }
        module Callback = ExtensionPoint_Callback.Make(CallbackSpec, Spec, Mappings)

        let commandTopic = SpecificCommandTopic.make(
          ~name=childName,
          ~channel=commandTopicChannel,
          ~commandsHandler=Callback.incomingCommandsHandler,
          ~opts,
        )

        module SpecificEventTopic = EventTopic.Make(SpecWithId, EventTopicAdapter)
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
      name,
      aggregateNames: Mappings.mappings->Belt.Array.keepMap((module(Mapping)) =>
        Mapping.mapOutgoingEvent->Belt.Option.map(_ => Mapping.aggregateName)
      ),
      commandTopic: commandTopic->Pulumi.Output.apply(commandTopic =>
        commandTopic->Component.extractOutputs
      ),
      eventTopic: eventTopic->Pulumi.Output.apply(eventTopic =>
        eventTopic->Component.extractOutputs
      ),
    })
  }

  let make = (~publishToAggregates, ~scheduler, ~queryEngine, ~opts) =>
    Component.make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~publishToAggregates, ~scheduler, ~queryEngine, ...),
      ~opts,
    )
}
