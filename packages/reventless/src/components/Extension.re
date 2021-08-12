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
type extension; // TODO: rename to t - after refactoring

type name = string;

type maker =
  (
    ~pluginExtensionPointCommandTopicId: Pulumi.Output.t(string),
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    unit
  ) =>
  Component.t(extension, outputs);

open ReventlessSpec.ExtensionMapping;

module type T = {
  module Spec: Spec;
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec;
  let make: (string, array(module Mapping)) => maker;
};

module Make = (Spec: Spec) : (T with module Spec := Spec) => {
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec;

  type constructed;
  type construct = (Component.t(extension, outputs), string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(extension, outputs) =
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
  external registerOutputs:
    (Component.t(extension, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(extension, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  module Mapper = {
    let findOutgoingMapping = (aggregateNameOpt, mappings) =>
      aggregateNameOpt->Belt.Option.flatMap(aggregateName =>
        mappings->Belt.Array.getBy((module Mapping: Mapping) =>
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
      ->Belt.Array.map((module Mapping: Mapping) =>
          Mapping.mapIncomingEvent(event', pluginDef, queryEngine)
        )
      ->Belt.Array.concatMany;

    let mapOutgoingEvent = (mappings: array(module Mapping), event'Json) =>
      switch (
        event'Json->Message.serviceNameOfMsg->findOutgoingMapping(mappings)
      ) {
      | Some((module Mapping)) => Mapping.mapOutgoingEvent(event'Json)
      | None =>
        Js.Exn.raiseError(
          "ExtensionPoint.Mapping: Missing mapping for "
          ++ event'Json->Js.Json.stringify,
        )
      };
  };

  let publishCommand = (id, cmdJson, queueId) =>
    cmdJson
    |> Js.Json.stringify
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

  let construct =
      (
        ~mappings,
        ~pluginExtensionPointCommandTopicId,
        ~queryEngine,
        self,
        name,
      ) => {
    let mapIncomingEvent = Mapper.mapIncomingEvent(mappings);
    let mapOutgoingEvent = Mapper.mapOutgoingEvent(mappings);

    let forwardCommand = (id, meta, extensionPointName, command'Json) =>
      publishCommand(
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
        publishCommand(
          id,
          command'Json,
          aggregateName->Util.Aggregate.commandTopicConnectorResource##id
          ->Pulumi.Output.get,
        )
      | ExtensionMapping.AbstractPublishAggregateCommandAsync(promise) =>
        promise->Js.Promise.then_(
                   ((aggregateName, id, command'Json)) =>
                     publishCommand(
                       id,
                       command'Json,
                       aggregateName->Util.Aggregate.commandTopicConnectorResource##id
                       ->Pulumi.Output.get,
                     ),
                   _,
                 )
      | ExtensionMapping.AbstractPublishAggregateCommandsAsync(promise) =>
        promise->Js.Promise.then_(
                   tupels =>
                     tupels
                     ->Belt.Array.map(((aggregateName, id, command'Json)) =>
                         publishCommand(
                           id,
                           command'Json,
                           aggregateName->Util.Aggregate.commandTopicConnectorResource##id
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
        publishCommand(
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
        publishCommand(
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
      ~name,
      ~extensionPointName=Spec.name,
      ~aggregateNames=
        mappings->Belt.Array.keepMap(((module Mapping)) =>
          Mapping.aggregateName == NoAggregate.name
            ? None : Some(Mapping.aggregateName)
        ),
      ~incomingEventHandler,
      ~outgoingEventHandler,
    )
    ->setOutputs(self, _);
  };

  let make: (string, array(module Mapping)) => maker =
    (
      nameSuffix,
      mappings,
      ~pluginExtensionPointCommandTopicId,
      ~queryEngine,
      ~opts,
      _,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name ++ "." ++ nameSuffix,
        ~construct=
          construct(
            ~mappings,
            ~pluginExtensionPointCommandTopicId,
            ~queryEngine,
          ),
        ~opts,
      );
};
