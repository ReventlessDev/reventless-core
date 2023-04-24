module ReventlessCommandTopic = CommandTopic
module ReventlessEventTopic = EventTopic

let componentType = ComponentType.ExtensionPoint

type name = string


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
): ReventlessSpec.ExtensionPoint.T => {
  module Spec = Spec

  module SpecWithId: ReventlessSpec.ExtensionPoint.Spec
    with type command = Spec.command
    and type event = Spec.event
    and type callCommand = Spec.callCommand = {
    include Spec
    module Id = ReventlessSpec.Id.String
  }

  module CommandTopic = CommandTopic.Make(SpecWithId, CommandTopicAdapter)

  module EventTopic = EventTopic.Make(SpecWithId, EventTopicAdapter)

  type t

  type constructed
  type construct = (ReventlessSpec.Component.t<t, ReventlessSpec.ExtensionPoint.outputs>, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => ReventlessSpec.Component.t<t,ReventlessSpec.ExtensionPoint.outputs> = "default"

  @obj
  external makeOutputs: (
    ~name: string,
    ~aggregateNames: array<string>,
    ~outgoingEventHandler: (. Js.Json.t, ReventlessSpec.Plugin.pluginDefinition) => Js.Promise.t<unit>,
    ~commandTopic: ReventlessSpec.CommandTopic.outputs,
    ~eventTopic: ReventlessSpec.EventTopic.outputs,
  ) => ReventlessSpec.ExtensionPoint.outputs = ""

  @send
  external registerOutputs: (ReventlessSpec.Component.t<t,ReventlessSpec.ExtensionPoint.outputs> , ReventlessSpec.ExtensionPoint.outputs) => constructed = "registerOutputs"
  @send external setOutputs: (ReventlessSpec.Component.t<t,ReventlessSpec.ExtensionPoint.outputs>, ReventlessSpec.ExtensionPoint.outputs) => unit = "setOutputs"
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

    let mapOutgoingEvent = (event'Json, mappings, scheduler, queue) =>
      switch event'Json->Message.serviceNameOfMsg->findOutgoingMapping(mappings) {
      | Some(module(Mapping)) =>
        Mapping.mapOutgoingEvent(
          event'Json,
          Schedule.create(scheduler, queue),
          Schedule.delete(scheduler, queue),
        )
      | None =>
        Js.Exn.raiseError(
          "ExtensionPoint.Mapping: Missing mapping for " ++ event'Json->Js.Json.stringify,
        )
      }
  }

  let construct = (~publishToAggregates, ~scheduler, ~queryEngine, self, name) => {
    let opts = Pulumi.ComponentResource.Options.make(~parent=self->Component.toPulumiResource, ())

    let childName = name->Js.String2.replace(".", "")->ComponentType.name(componentType)

    let commandTopic: ref<
      option<ReventlessSpec.Component.t<CommandTopic.t, ReventlessSpec.CommandTopic.outputs>>,
    > = ref(None)

    let applyCommandAction = x =>
      switch x {
      | ExtensionPointMapping.AbstractPublishCommand(aggregateName, reference, cmdJson) =>
        publishToAggregates
        ->Js.Dict.get(aggregateName)
        ->Belt.Option.map((publishJsons: ReventlessSpec.CommandTopic.publishJsons) =>
          publishJsons(. [cmdJson])
        )
        ->Belt.Option.mapWithDefault(
          _,
          () =>
            Js.Exn.raiseError(
              `ExtensionPoint.applyCommandAction: Aggregate ${aggregateName} doesn't exist`,
            ),
          (x, ()) => x,
        )()
        ->Js.Promise.then_(_ => Belt.Result.Ok(reference)->Js.Promise.resolve, _)
        ->Js.Promise.catch(err => {
          Js.log2("ExtensionPoint: Error on publish command:", err)
          Belt.Result.Error(reference)->Js.Promise.resolve
        }, _)
      | AbstractCall(reference, handler) =>
        handler()
        ->Js.Promise.then_(_ => Belt.Result.Ok(reference)->Js.Promise.resolve, _)
        ->Js.Promise.catch(err => {
          err->Js.log2("ExtensionPoint: Error on calling handler:")
          Belt.Result.Error(reference)->Js.Promise.resolve
        }, _)
      }

    let eventTopic = EventTopic.make(~name=childName, ~storageResources=[], ~opts, ())

    let applyEventAction = x =>
      switch x {
      | ExtensionPointMapping.AbstractPublishEvent(event') =>
        let publish = EventTopic.publish(eventTopic)
        publish(. [event'])->Js.Promise.catch(
          err => err->Js.log2("ExtensionPoint: Error on publish command:")->Js.Promise.resolve,
          _,
        )
      | ExtensionPointMapping.AbstractPublishEventAsync(promise) =>
        let publish = EventTopic.publish(eventTopic)
        promise->Js.Promise.then_(
          event' =>
            publish(. [event'])->Js.Promise.catch(
              err => err->Js.log2("ExtensionPoint: Error on publish command:")->Js.Promise.resolve,
              _,
            ),
          _,
        )
      | AbstractCall(handler) =>
        handler()->Js.Promise.catch(
          err => err->Js.log2("ExtensionPoint: Error on calling handler:")->Js.Promise.resolve,
          _,
        )
      }

    let outgoingEventHandler = (. event'Json, pluginDef) => {
      let commandTopic = commandTopic.contents->Belt.Option.getExn
      let eventActions =
        event'Json->Mapper.mapOutgoingEvent(
          Mappings.mappings,
          scheduler,
          (commandTopic->Component.extractOutputs)["resources"],
          pluginDef,
          queryEngine,
        )

      eventActions->Belt.Array.map(applyEventAction)
      |> Js.Promise.all
      |> Js.Promise.then_(_ => Js.Promise.resolve())
    }

    let incomingCommandsHandler = (. topicItems) => {
      let commandTopic = commandTopic.contents->Belt.Option.getExn
      let commandActions =
        topicItems->Mapper.mapIncomingCommands(
          Mappings.mappings,
          scheduler,
          queryEngine,
          (commandTopic->Component.extractOutputs)["resources"],
        )

      commandActions->Belt.Array.map(applyCommandAction)->Js.Promise.all
    }

    commandTopic :=
      Some(CommandTopic.make(~name=childName, ~commandsHandler=incomingCommandsHandler, ~opts, ()))

    makeOutputs(
      ~name,
      ~aggregateNames=Mappings.mappings->Belt.Array.map((module(Mapping)) => Mapping.aggregateName),
      ~outgoingEventHandler,
      ~commandTopic=commandTopic.contents->Belt.Option.getExn->Component.extractOutputs,
      ~eventTopic=eventTopic->Component.extractOutputs,
    )->setOutputs(self, _)
  }

  let make = (~publishToAggregates, ~scheduler, ~queryEngine, ~opts, _) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~publishToAggregates, ~scheduler, ~queryEngine),
      ~opts,
    )
}
