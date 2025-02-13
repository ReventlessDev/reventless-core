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
  eventTopic: EventTopic.outputs,
}

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
  CommandTopicAdapter: CommandTopic_Adapter.Connector,
  EventTopicAdapter: EventTopic.Adapter.Publisher,
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

    let commandTopicResources: ref<Pulumi.Output.t<array<Adapter.unwrappedResource>>> = ref(
      []->Pulumi.Output.make,
    )

    module SpecificEventTopic = EventTopic.Make(SpecWithId, EventTopicAdapter)
    let eventTopic = SpecificEventTopic.make(~name=childName, ~storageResources=[], ~opts)

    let (outgoingEventHandler, incomingCommandsHandler) =
      (eventTopic->Component.operations, commandTopicResources.contents)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply((({publishJson: publishToEventTopic}, commandTopicResources)) => {
        module RuntimeSpec = {
          let publishToAggregates = publishToAggregates
          let publishToEventTopic = publishToEventTopic
          let commandTopicResources = commandTopicResources
          let scheduler = scheduler
          let queryEngine = queryEngine
        }
        module Runtime = ExtensionPoint_Runtime.Make(RuntimeSpec, Spec, Mappings)

        (Runtime.outgoingEventHandler, Runtime.incomingCommandsHandler)
      })
      ->Pulumi.Output.unzip

    module SpecificCommandTopic = CommandTopic_Builder.Make(SpecWithId, CommandTopicAdapter)
    let commandTopic = incomingCommandsHandler->Pulumi.Output.apply(incomingCommandsHandler => {
      let commandTopic = SpecificCommandTopic.make(
        ~name=childName,
        ~commandsHandler=incomingCommandsHandler,
        ~opts,
      )
      commandTopicResources :=
        (commandTopic->Component.extractOutputs).resources->Adapter.resourcesToUnwrappedOutput
      commandTopic
    })

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
      eventTopic: eventTopic->Component.extractOutputs,
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
