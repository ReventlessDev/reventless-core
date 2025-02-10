let componentType = ComponentType.ExtensionPoint

type outputs = {
  name: string,
  aggregateNames: array<string>,
  commandTopic: CommandTopic.outputs,
  eventTopic: EventTopic.outputs,
}

type unwrappedOutputs = {
  name: string,
  aggregateNames: array<string>,
  commandTopic: CommandTopic.unwrappedOutputs,
  eventTopic: EventTopic.unwrappedOutputs,
}

type t
type component = Component.t<t, outputs, unit>

type eventHandler = (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>

module type T = {
  let make: (
    ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~scheduler: Scheduler.operations,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component

  let outgoingEventHandler: component => Pulumi.Output.t<eventHandler>
}

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := Spec,
  CommandTopicAdapter: CommandTopic.Adapter.Connector,
  EventTopicAdapter: EventTopic.Adapter.Publisher,
): T => {
  module Spec = Spec

  module SpecWithId: ReventlessSpec.ExtensionPoint.Spec
    with type command = Spec.command
    and type event = Spec.event
    and type callCommand = Spec.callCommand = {
    include Spec
    module Id = ReventlessSpec.Id.String
  }

  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send
  external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setOutgoingEventHandler: (component, Pulumi.Output.t<eventHandler>) => unit =
    "outgoingEventHandler"
  @get
  external outgoingEventHandler: component => Pulumi.Output.t<eventHandler> = "outgoingEventHandler"

  let construct = (
    ~publishToAggregates,
    ~scheduler: Scheduler.operations,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let childName = name->Js.String2.replace(".", "")->ComponentType.name(componentType)

    let commandTopic: ref<option<CommandTopic.component>> = ref(None)
    let commandTopicResources =
      (
        commandTopic.contents->Belt.Option.getExn->Component.extractOutputs
      ).resources->Adapter.resourcesToUnwrappedOutput

    module SpecificEventTopic = EventTopic.Make(SpecWithId, EventTopicAdapter)
    let eventTopic = SpecificEventTopic.make(~name=childName, ~storageResources=[], ~opts)

    let (outgoingEventHandler, incomingCommandsHandler) =
      (eventTopic->Component.operations, commandTopicResources)
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

    module SpecificCommandTopic = CommandTopic.Make(SpecWithId, CommandTopicAdapter)
    let _ =
      incomingCommandsHandler->Pulumi.Output.apply(incomingCommandsHandler =>
        commandTopic :=
          Some(
            SpecificCommandTopic.make(
              ~name=childName,
              ~commandsHandler=incomingCommandsHandler,
              ~opts,
            ),
          )
      )

    self->setOutgoingEventHandler(outgoingEventHandler)

    self->setOutputs({
      name,
      aggregateNames: Mappings.mappings->Belt.Array.keepMap((module(Mapping)) =>
        Mapping.mapOutgoingEvent->Belt.Option.map(_ => Mapping.aggregateName)
      ),
      commandTopic: commandTopic.contents->Belt.Option.getExn->Component.extractOutputs,
      eventTopic: eventTopic->Component.extractOutputs,
    })
  }

  let make = (~publishToAggregates, ~scheduler, ~queryEngine, ~opts) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~publishToAggregates, ~scheduler, ~queryEngine, ...),
      ~opts,
    )
}
