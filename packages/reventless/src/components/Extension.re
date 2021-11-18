open ReventlessSpec.Adapter;

let componentType = ComponentType.Extension;

type outputs = {
  .
  "name": string,
  "extensionPointName": string,
  "aggregateNames": array(string),
  "incomingEventHandler":
    (. Js.Json.t, PluginSpec.pluginDefinition) => Js.Promise.t(unit),
  "outgoingEventHandler":
    (. Js.Json.t, PluginSpec.pluginDefinition) => Js.Promise.t(unit),
};
type t;
type component = Component.t(t, outputs);

type name = string;

type maker =
  (
    ~pluginExtensionPointCommandTopicId: Pulumi.Output.t(string),
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~resources: resources,
    unit
  ) =>
  component;

open ReventlessSpec.ExtensionMapping;

module type T = {let make: maker;};

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionMapping.Spec;
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec;
  let name: string;
  let mappings: array(module Mapping);
};

module Make = (Spec: Spec, Mappings: Mappings with module Spec := Spec) : T => {
  type constructed;
  type construct = (component, string, resources) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources
    ) =>
    component =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~name: string,
      ~extensionPointName: string,
      ~aggregateNames: array(string),
      ~incomingEventHandler: (. Js.Json.t, PluginSpec.pluginDefinition) =>
                             Js.Promise.t(unit),
      ~outgoingEventHandler: (. Js.Json.t, PluginSpec.pluginDefinition) =>
                             Js.Promise.t(unit)
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  module Mapper = {
    let findOutgoingMapping = (aggregateNameOpt, mappings) =>
      aggregateNameOpt->Belt.Option.flatMap(aggregateName =>
        mappings->Belt.Array.getBy((module Mapping: Mappings.Mapping) =>
          Mapping.aggregateName == aggregateName
        )
      ); // TODO: handle multiple mappings for same Aggregate name

    let mapIncomingEvent =
        (
          mappings,
          event': Message.event'(Id.String.t, Spec.event),
          pluginDef,
          queryEngine,
        ) =>
      mappings
      ->Belt.Array.map((module Mapping: Mappings.Mapping) =>
          Mapping.mapIncomingEvent(event', pluginDef, queryEngine)
        )
      ->Belt.Array.concatMany;

    let mapOutgoingEvent = (mappings, event'Json) =>
      switch (
        event'Json
        ->Message.serviceNameOfMsg
        ->findOutgoingMapping(Mappings.mappings)
      ) {
      | Some((module Mapping)) => Mapping.mapOutgoingEvent(event'Json)
      | None =>
        Js.Exn.raiseError(
          "ExtensionPoint.Mapping: Missing mapping for "
          ++ event'Json->Js.Json.stringify,
        )
      };
  };

  let publishAggregateCommand = (id, cmdJson, queueId) =>
    cmdJson
    |> Js.Json.stringify  // TODO: move to Adapter
    |> AwsSdk.SQS.sendMessage(
         ~queueId,
         ~messageGroupId=id,
         ~messageBody=_,
         (),
       )
    |> Js.Promise.catch(err =>
         err
         |> Js.log2("Extension: Error on publish command:")
         |> Js.Promise.resolve
       );

  let publishExtensionPointCommand = (id, cmdJson, queueId) =>
    cmdJson
    |> Js.Json.stringify  // TODO: move to Adapter
    |> AwsSdk.SQS.sendMessage(
         ~queueId,
         // ~messageGroupId=id,
         ~messageBody=_,
         (),
       )
    |> Js.Promise.catch(err =>
         err
         |> Js.log2("Extension: Error on publish command:")
         |> Js.Promise.resolve
       );

  let construct =
      (
        ~pluginExtensionPointCommandTopicId,
        ~queryEngine,
        self,
        name,
        resources,
      ) => {
    let mapIncomingEvent = Mapper.mapIncomingEvent(Mappings.mappings);
    let mapOutgoingEvent = Mapper.mapOutgoingEvent(Mappings.mappings);

    let forwardCommand = (id, meta, extensionPointName, command'Json) =>
      publishExtensionPointCommand(
        id,
        Message.command'_encode(
          Id.String.t_encode,
          ReventlessSpec.PluginExtensionPointSpec.command_encode,
          {
            id: id->Id.String.makeFromString,
            meta: {
              ...meta,
              msgId: Message.uuid(),
            },
            command:
              ForwardCommand({
                extensionPointName,
                id,
                command: command'Json->Js.Json.stringify,
              }),
          },
        ),
        pluginExtensionPointCommandTopicId->Pulumi.Output.get,
      );

    let applyIncomingCommandAction =
      fun
      | ExtensionMapping.AbstractPublishAggregateCommand(
          aggregateName,
          id,
          command'Json,
        ) =>
        publishAggregateCommand(
          id,
          command'Json,
          resources->Util.Aggregate.commandTopicConnectorResource(
            aggregateName,
          )##id
          ->Pulumi.Output.get,
        )
      | ExtensionMapping.AbstractPublishAggregateCommandAsync(promise) =>
        promise->Js.Promise.then_(
                   ((aggregateName, id, command'Json)) =>
                     publishAggregateCommand(
                       id,
                       command'Json,
                       resources->Util.Aggregate.commandTopicConnectorResource(
                         aggregateName,
                       )##id
                       ->Pulumi.Output.get,
                     ),
                   _,
                 )
      | ExtensionMapping.AbstractPublishAggregateCommandsAsync(promise) =>
        promise->Js.Promise.then_(
                   tupels =>
                     tupels
                     ->Belt.Array.map(((aggregateName, id, command'Json)) =>
                         publishAggregateCommand(
                           id,
                           command'Json,
                           resources->Util.Aggregate.commandTopicConnectorResource(
                             aggregateName,
                           )##id
                           ->Pulumi.Output.get,
                         )
                       )
                     ->Js.Promise.all
                     ->Js.Promise.then_(_ => Js.Promise.resolve(), _),
                   _,
                 )
      | ExtensionMapping.AbstractPublishPluginExtensionPointCommand(
          id,
          command'Json,
        ) =>
        publishExtensionPointCommand(
          id,
          command'Json,
          pluginExtensionPointCommandTopicId->Pulumi.Output.get,
        )
      | ExtensionMapping.AbstractPublishExtensionPointCommand(
          extensionPointName,
          id,
          meta,
          command'Json,
        ) =>
        forwardCommand(id, meta, extensionPointName, command'Json)
      | AbstractCall(handler) =>
        handler()
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on calling handler:")
             |> Js.Promise.resolve
           );

    let applyOutgoingCommandAction =
      fun
      | ExtensionMapping.AbstractPublishPluginExtensionPointCommand(
          id,
          command'Json,
        ) =>
        publishExtensionPointCommand(
          id,
          command'Json,
          pluginExtensionPointCommandTopicId->Pulumi.Output.get,
        )
      | ExtensionMapping.AbstractPublishExtensionPointCommand(
          extensionPointName,
          id,
          meta,
          command'Json,
        ) =>
        forwardCommand(id, meta, extensionPointName, command'Json)
      | AbstractCall(handler) =>
        handler()
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on calling handler:")
             |> Js.Promise.resolve
           );

    let incomingEventHandler =
      (. event'Json, pluginDef) => {
        let event' =
          Message.event'_decode(
            Id.String.t_decode,
            Spec.event_decode,
            event'Json,
          );

        switch (event') {
        | Belt.Result.Ok(event') =>
          let commandActions =
            mapIncomingEvent(event', pluginDef, queryEngine);
          commandActions->Belt.Array.map(applyIncomingCommandAction)
          |> Js.Promise.all
          |> Js.Promise.then_(_ => Js.Promise.resolve());
        | Error(msg) =>
          Js.log2("Could not decode event':", msg);
          Js.Promise.resolve();
        };
      };

    let outgoingEventHandler =
      (. event'Json, pluginDef) => {
        let commandActions = mapOutgoingEvent(event'Json, pluginDef);
        commandActions->Belt.Array.map(applyOutgoingCommandAction)
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());
      };

    makeOutputs(
      ~name=name ++ Mappings.name,
      ~extensionPointName=Spec.name,
      ~aggregateNames=
        Mappings.mappings->Belt.Array.keepMap(((module Mapping)) =>
          Mapping.aggregateName == NoAggregate.name
            ? None : Some(Mapping.aggregateName)
        ),
      ~incomingEventHandler,
      ~outgoingEventHandler,
    )
    ->setOutputs(self, _);
  };

  let make: maker =
    (~pluginExtensionPointCommandTopicId, ~queryEngine, ~opts, ~resources, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=
          construct(~pluginExtensionPointCommandTopicId, ~queryEngine),
        ~opts,
        ~resources,
      );
};
