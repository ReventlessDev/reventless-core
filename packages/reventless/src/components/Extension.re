let componentType = ComponentType.Extension;

type outputs = {
  .
  "name": string,
  "extensionPointName": string,
  "aggregateNames": array(string),
  "incomingEventHandler": (. Js.Json.t) => Js.Promise.t(unit),
  "outgoingEventHandler": (. Js.Json.t) => Js.Promise.t(unit),
};
type extension; // TODO: rename to t - after refactoring

type name = string;

type maker =
  (
    ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
    ~queryExtensionPointCommandTopicId: string =>
                                        Js.Promise.t(option(string)),
    ~opts: option(Pulumi.ComponentResource.Options.t),
    unit
  ) =>
  Component.t(extension, outputs);

module type Spec = {
  module Id = Id.String;

  let name: string;

  [@decco]
  type command;
  [@decco]
  type event;
  [@decco]
  type callCommand;
};

module type T = {
  module Spec: ExtensionMapping.Spec;
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec;
  let make: (string, array(module Mapping)) => maker;
};

module Make = (Spec: ExtensionMapping.Spec) : (T with module Spec := Spec) => {
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec;

  module SpecWithId:
    Spec with
      type command = Spec.command and
      type event = Spec.event and
      type callCommand = Spec.callCommand = {
    include Spec;
    module Id = Id.String;
    let name = name ++ componentType->ComponentType.toString;
  };

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
      ~incomingEventHandler: (. Js.Json.t) => Js.Promise.t(unit),
      ~outgoingEventHandler: (. Js.Json.t) => Js.Promise.t(unit)
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
        (mappings, event': Message.event'(Id.String.t, Spec.event)) =>
      mappings
      ->Belt.Array.map((module Mapping: Mapping) =>
          Mapping.mapIncomingEvent(event')
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

  let publishCommand = (cmdJson, queueId) =>
    cmdJson
    |> Js.Json.stringify
    |> AwsSdk.SQS.sendMessage(~queueId, ~messageBody=_, ())
    |> Js.Promise.catch(err =>
         err
         |> Js.log2("Extension: Error on publish command:")
         |> Js.Promise.resolve
       );

  let construct =
      (
        ~mappings,
        ~queryCommandTopic,
        ~queryExtensionPointCommandTopicId,
        self,
        name,
      ) => {
    let mapIncomingEvent = Mapper.mapIncomingEvent(mappings);
    let mapOutgoingEvent = Mapper.mapOutgoingEvent(mappings);

    let applyIncomingCommandAction =
      fun
      | ExtensionMapping.AbstractPublishAggregateCommand(
          aggregateName,
          command'Json,
        ) =>
        publishCommand(
          command'Json,
          queryCommandTopic(aggregateName)##id->Pulumi.Output.get,
        )
      | ExtensionMapping.AbstractPublishExtensionPointCommand(command'Json) =>
        queryExtensionPointCommandTopicId(Spec.name)
        ->Js.Promise.then_(
            extensionPointCommandTopic =>
              extensionPointCommandTopic->Belt.Option.mapWithDefaultU(
                Js.Promise.resolve(), (. extensionPointCommandTopic) =>
                publishCommand(command'Json, extensionPointCommandTopic)
              ),
            _,
          )
      | AbstractCall(handler) =>
        handler()
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on calling handler:")
             |> Js.Promise.resolve
           );

    let applyOutgoingCommandAction =
      fun
      | ExtensionMapping.AbstractPublishExtensionPointCommand(command'Json) =>
        queryExtensionPointCommandTopicId(Spec.name)
        ->Js.Promise.then_(
            extensionPointCommandTopic =>
              extensionPointCommandTopic->Belt.Option.mapWithDefaultU(
                Js.Promise.resolve(), (. extensionPointCommandTopic) =>
                publishCommand(command'Json, extensionPointCommandTopic)
              ),
            _,
          )
      | AbstractCall(handler) =>
        handler()
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on calling handler:")
             |> Js.Promise.resolve
           );

    let incomingEventHandler =
      (. event'Json) => {
        let event' =
          Message.event'_decode(
            Id.String.t_decode,
            Spec.event_decode,
            event'Json,
          );

        switch (event') {
        | Belt.Result.Ok(event') =>
          event'->mapIncomingEvent->Belt.Array.map(applyIncomingCommandAction)
          |> Js.Promise.all
          |> Js.Promise.then_(_ => Js.Promise.resolve())
        | Error(msg) =>
          Js.log2("Could not decode event':", msg)->Js.Promise.resolve
        };
      };

    let outgoingEventHandler =
      (. event'Json) =>
        event'Json
        ->mapOutgoingEvent
        ->Belt.Array.map(applyOutgoingCommandAction)
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());

    makeOutputs(
      ~name,
      ~extensionPointName=Spec.name,
      ~aggregateNames=
        mappings->Belt.Array.map(((module Mapping)) => Mapping.aggregateName),
      ~incomingEventHandler,
      ~outgoingEventHandler,
    )
    ->setOutputs(self, _);
  };

  let make: (string, array(module Mapping)) => maker =
    (
      nameSuffix,
      mappings,
      ~queryCommandTopic,
      ~queryExtensionPointCommandTopicId,
      ~opts,
      _,
    ) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name ++ "." ++ nameSuffix,
        ~construct=
          construct(
            ~mappings,
            ~queryCommandTopic,
            ~queryExtensionPointCommandTopicId,
          ),
        ~opts,
      );
};
