module ReventlessCommandTopic = CommandTopic
module ReventlessEventTopic = EventTopic

let componentType = ComponentType.ExtensionPoint

type outputs = {
  name: string,
  aggregateNames: array<string>,
  outgoingEventHandler: (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>,
  commandTopic: CommandTopic.outputs,
  eventTopic: EventTopic.outputs,
}

type unwrappedOutputs = {
  name: string,
  aggregateNames: array<string>,
  outgoingEventHandler: (Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>,
  commandTopic: CommandTopic.unwrappedOutputs,
  eventTopic: EventTopic.unwrappedOutputs,
}

type t
type component = ReventlessSpec.Component.t<t, outputs>

module type T = {
  type t
  let make: (
    ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~scheduler: ReventlessSpec.Scheduler.t,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
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

  type t

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

  module Mapper = {
    let findOutgoingMapping = (aggregateNameOpt, mappings) =>
      aggregateNameOpt->Belt.Option.flatMap(aggregateName =>
        mappings->Belt.Array.getBy((module(Mapping: Mappings.Mapping)) =>
          Mapping.aggregateName == aggregateName
        )
      ) // TODO: handle multiple mappings for same Aggregate name

    let mapIncomingCommands = (topicItems, mappings, scheduler, queryEngine, queue) =>
      mappings
      ->Belt.Array.map((module(Mapping: Mappings.Mapping)) =>
        Mapping.mapIncomingCommands(
          topicItems,
          Schedule.create(scheduler, queue),
          Schedule.delete(scheduler, queue),
          queryEngine,
        )
      )
      ->Belt.Array.concatMany

    let mapOutgoingEvent = (event'Json, mappings, scheduler, queue, queryEngine) =>
      switch event'Json->Message.serviceNameOfMsg->findOutgoingMapping(mappings) {
      | Some(module(Mapping)) =>
        switch Mapping.mapOutgoingEvent {
        | Some(mapOutgoingEvent) =>
          mapOutgoingEvent(
            event'Json,
            Schedule.create(scheduler, queue),
            Schedule.delete(scheduler, queue),
            queryEngine,
          )
        | None =>
          Logger.error(
            ~loc=__LOC__,
            "mapOutgoingEvent",
            "shouldn't be called, because Plugin EventCollector shouldn't subscribe to EventLog stream not having mapOutgoingEvent() !",
          )
          []
        }
      | None =>
        Js.Exn.raiseError(
          "ExtensionPoint.Mapping: Missing mapping for " ++ event'Json->Js.Json.stringify,
        )
      }
  }

  let construct = (~publishToAggregates, ~scheduler, ~queryEngine, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let childName = name->Js.String2.replace(".", "")->ComponentType.name(componentType)

    let commandTopic: ref<option<CommandTopic.component>> = ref(None)

    let applyCommandAction = async action =>
      switch action {
      | ExtensionPointMapping.AbstractPublishCommand(aggregateName, reference, cmdJson) =>
        let result =
          publishToAggregates
          ->Js.Dict.get(aggregateName)
          ->Belt.Option.map((publishJsons: ReventlessSpec.CommandTopic.publishJsons) =>
            publishJsons([cmdJson])
          )
          ->Belt.Option.mapWithDefault(
            () =>
              Js.Exn.raiseError(
                `ExtensionPoint.applyCommandAction: Aggregate ${aggregateName} doesn't exist`,
              ),
            x => {() => x},
          )
        switch result() {
        | _ => Belt.Result.Ok(reference)
        | exception err => {
            Js.log2("ExtensionPoint: Error on publish command:", err)
            Belt.Result.Error(reference)
          }
        }
      | AbstractCall(reference, handler) =>
        switch await handler() {
        | _ => Belt.Result.Ok(reference)
        | exception err => {
            err->Js.log2("ExtensionPoint: Error on calling handler:")
            Belt.Result.Error(reference)
          }
        }
      }

    module EventTopic = EventTopic.Make(SpecWithId, EventTopicAdapter)
    let eventTopic = EventTopic.make(~name=childName, ~storageResources=[], ~opts)
    let publish = EventTopic.publish(eventTopic)

    let applyEventAction = async action =>
      switch action {
      | ExtensionPointMapping.AbstractPublishEvent(event') =>
        try await publish([event']) catch {
        | err => err->Js.log2("ExtensionPoint: Error on publish command:")
        }
      | ExtensionPointMapping.AbstractPublishEventAsync(promise) =>
        let publish = async promise =>
          try await publish([await promise]) catch {
          | err => err->Js.log2("ExtensionPoint: Error on publish command:")
          }
        await promise->publish
      | AbstractCall(handler) =>
        try await handler() catch {
        | err => err->Js.log2("ExtensionPoint: Error on calling handler:")
        }
      }

    let outgoingEventHandler = async (event'Json, _pluginDef) => {
      let commandTopic = commandTopic.contents->Belt.Option.getExn
      let eventActions = Mapper.mapOutgoingEvent(
        event'Json,
        Mappings.mappings,
        scheduler,
        (commandTopic->Component.extractOutputs).resources,
        queryEngine,
      )

      await eventActions->Belt.Array.map(applyEventAction)->Js.Promise.all->Util.Promise.toUnit
    }

    let incomingCommandsHandler = topicItems => {
      let commandTopic = commandTopic.contents->Belt.Option.getExn
      let commandActions =
        topicItems->Mapper.mapIncomingCommands(
          Mappings.mappings,
          scheduler,
          queryEngine,
          (commandTopic->Component.extractOutputs).resources,
        )

      commandActions->Belt.Array.map(applyCommandAction)->Js.Promise.all
    }

    module CommandTopic = CommandTopic.Make(SpecWithId, CommandTopicAdapter)
    commandTopic :=
      Some(CommandTopic.make(~name=childName, ~commandsHandler=incomingCommandsHandler, ~opts))

    self->setOutputs({
      name,
      aggregateNames: Mappings.mappings->Belt.Array.keepMap((module(Mapping)) =>
        Mapping.mapOutgoingEvent->Belt.Option.map(_ => Mapping.aggregateName)
      ),
      outgoingEventHandler,
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
