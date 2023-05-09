let componentType = ComponentType.Extension

type outputs = {
  "name": string,
  "extensionPointName": string,
  "aggregateNames": array<string>,
  "incomingEventHandler": (
    . Js.Json.t,
    ReventlessSpec.Plugin.pluginDefinition,
  ) => Js.Promise.t<unit>,
  "outgoingEventHandler": (
    . Js.Json.t,
    ReventlessSpec.Plugin.pluginDefinition,
  ) => Js.Promise.t<unit>,
}
type t
type component = ReventlessSpec.Component.t<t, outputs>

type name = string

open ReventlessSpec.ExtensionMapping

module type T = {
  let make: (
    ~publishToCorePluginExtensionPoint: ReventlessSpec.CommandTopic.publishJsons,
    ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
    unit,
  ) => component
}

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionMapping.Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name: string
  let mappings: array<module(Mapping)>
}

module Make = (Spec: Spec, Mappings: Mappings with module Spec := Spec): T => {
  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => component = "default"

  @obj
  external makeOutputs: (
    ~name: string,
    ~extensionPointName: string,
    ~aggregateNames: array<string>,
    ~incomingEventHandler: (
      . Js.Json.t,
      ReventlessSpec.Plugin.pluginDefinition,
    ) => Js.Promise.t<unit>,
    ~outgoingEventHandler: (
      . Js.Json.t,
      ReventlessSpec.Plugin.pluginDefinition,
    ) => Js.Promise.t<unit>,
  ) => outputs = ""

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  let findOutgoingMapping = (aggregateNameOpt, mappings) =>
    aggregateNameOpt->Belt.Option.flatMap(aggregateName =>
      mappings->Belt.Array.getBy((module(Mapping: Mappings.Mapping)) =>
        Mapping.aggregateName == aggregateName
      )
    ) // TODO: handle multiple mappings for same Aggregate name

  let mapIncomingEvent = (event': Message.event'<string, Spec.event>, pluginDef, queryEngine) =>
    Mappings.mappings
    ->Belt.Array.map((module(Mapping: Mappings.Mapping)) =>
      Mapping.mapIncomingEvent(event', pluginDef, queryEngine)
    )
    ->Belt.Array.concatMany

  let mapOutgoingEvent = event'Json =>
    switch event'Json->Message.serviceNameOfMsg->findOutgoingMapping(Mappings.mappings) {
    | Some(module(Mapping)) => Mapping.mapOutgoingEvent(event'Json)
    | None =>
      Js.Exn.raiseError(
        "ExtensionPoint.Mapping: Missing mapping for " ++ event'Json->Js.Json.stringify,
      )
    }

  let construct = (
    ~publishToCorePluginExtensionPoint,
    ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~queryEngine,
    self,
    name,
  ) => {
    let publishAggregateCommand = async (aggregateName, cmdJson) => {
      let pub = publishToAggregates->Js.Dict.get(aggregateName)->Belt.Option.getExn
      try await pub(. [cmdJson]) catch {
      | err => Js.log2(`Extension: Error on publish command to aggregate ${aggregateName}:`, err)
      }
    }

    let publishCorePluginExtensionPointCommand = async cmdJson =>
      try await publishToCorePluginExtensionPoint(. [cmdJson]) catch {
      | err => Js.log2(`Extension: Error on publish command to Core.Plugin ExtensionPoint:`, err)
      }

    let forwardCommand = (extensionPointName, commandJson: Message.commandJson) =>
      publishCorePluginExtensionPointCommand({
        Message.id: "",
        meta: {
          ...commandJson.meta,
          msgId: Message.uuid(),
        },
        commandJson: ForwardCommand({
          extensionPointName,
          id: commandJson.id,
          command: commandJson->Message.toMessageBody,
        })->ReventlessSpec.PluginExtensionPointSpec.command_encode,
        delay: None,
      })

    let handle = async handler =>
      try await handler() catch {
      | err => Js.log2("ExtensionPoint: Error on calling handler:", err)
      }

    let applyIncomingCommandAction = async action =>
      await (
        switch action {
        | ExtensionMapping.AbstractPublishAggregateCommand(aggregateName, commandJson) =>
          publishAggregateCommand(aggregateName, commandJson)
        | AbstractPublishAggregateCommandAsync(promise) => {
            let (aggregateName, commandJson) = await promise
            publishAggregateCommand(aggregateName, commandJson)
          }
        | AbstractPublishAggregateCommandsAsync(promise) =>
          let publish = async promise => {
            await promise
            ->Util.Promise.mapOk(arr =>
              arr
              ->Belt.Array.map(((aggregateName, commandJson)) =>
                publishAggregateCommand(aggregateName, commandJson)
              )
              ->Js.Promise.all
            )
            ->Util.Promise.toUnit
          }
          promise->publish
        | AbstractPublishPluginExtensionPointCommand(commandJson) =>
          publishCorePluginExtensionPointCommand(commandJson)
        | AbstractPublishExtensionPointCommand(extensionPointName, commandJson) =>
          forwardCommand(extensionPointName, commandJson)
        | AbstractCall(handler) => handler->handle
        }
      )

    let applyOutgoingCommandAction = async action =>
      switch action {
      | ExtensionMapping.AbstractPublishPluginExtensionPointCommand(commandJson) =>
        publishCorePluginExtensionPointCommand(commandJson)
      | AbstractPublishExtensionPointCommand(extensionPointName, commandJson) =>
        forwardCommand(extensionPointName, commandJson)
      | AbstractCall(handler) => handler->handle
      }

    let incomingEventHandler = async (. event'Json, pluginDef) => {
      let event' = Message.event'_decode(
        ReventlessSpec.Id.StringPure.t_decode,
        Spec.event_decode,
        event'Json,
      )

      switch event' {
      | Belt.Result.Ok(event') =>
        let commandActions = mapIncomingEvent(event', pluginDef, queryEngine)
        let apply = async commandActions => {
          await commandActions
          ->Belt.Array.map(applyIncomingCommandAction)
          ->Js.Promise.all
          ->Util.Promise.toUnit
        }
        await commandActions->apply
      | Error(msg) => Js.log2("Could not decode event':", msg)
      }
    }

    let outgoingEventHandler = (. event'Json, pluginDef) => {
      let commandActions = mapOutgoingEvent(event'Json, pluginDef)
      commandActions
      ->Belt.Array.map(applyOutgoingCommandAction)
      ->Js.Promise.all
      ->Util.Promise.toUnit
    }

    self->setOutputs(
      makeOutputs(
        ~name,
        ~extensionPointName=Spec.name,
        ~aggregateNames=Mappings.mappings->Belt.Array.keepMap((module(Mapping)) =>
          Mapping.aggregateName == NoAggregate.name ? None : Some(Mapping.aggregateName)
        ),
        ~incomingEventHandler,
        ~outgoingEventHandler,
      ),
    )
  }

  let make: (
    ~publishToCorePluginExtensionPoint: ReventlessSpec.CommandTopic.publishJsons,
    ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
    unit,
  ) => component = (
    ~publishToCorePluginExtensionPoint,
    ~publishToAggregates,
    ~queryEngine,
    ~opts,
    _: unit,
  ) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name ++ ("." ++ Mappings.name),
      ~construct=construct(~publishToCorePluginExtensionPoint, ~publishToAggregates, ~queryEngine),
      ~opts,
    )
}
