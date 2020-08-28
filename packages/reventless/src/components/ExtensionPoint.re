let componentType = ComponentType.ExtensionPoint;

type outputs = {
  .
  "name": string,
  "aggregateNames": array(string),
  "eventHandler": (. Js.Json.t) => Js.Promise.t(unit),
  "commandTopic": CommandTopic.outputs,
  "eventTopic": EventTopic.outputs,
};
type t = outputs;

type name = string;

type maker =
  (
    ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    unit
  ) =>
  t;

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
  module Spec: ExtensionPointMapping.Spec;
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;
  let make: array(module Mapping) => maker;
};

module Make =
       (
         Spec: ExtensionPointMapping.Spec,
         CommandTopicAdapter: CommandTopic.Connector,
         EventTopicAdapter: EventTopic.Publisher,
       )
       : (T with module Spec := Spec) => {
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;

  module SpecWithId:
    Spec with
      type command = Spec.command and
      type event = Spec.event and
      type callCommand = Spec.callCommand = {
    include Spec;
    module Id = Id.String;
    let name =
      name->Js.String2.replace(".", "")
      ++ componentType->ComponentType.toString;
  };

  module CommandTopic = CommandTopic.Make(SpecWithId, CommandTopicAdapter);

  module EventTopic = EventTopic.Make(SpecWithId, EventTopicAdapter);

  type constructed;
  type construct = (t, string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    t =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~eventHandler: (. Js.Json.t) => Js.Promise.t(unit),
      ~commandTopic: CommandTopic.t,
      ~eventTopic: EventTopic.t
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
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

    let mapIncomingCommands =
        (
          mappings,
          commands': array(Message.command'(Id.String.t, Spec.command)),
        ) =>
      mappings
      ->Belt.Array.map((module Mapping: Mapping) =>
          Mapping.mapIncomingCommands(commands')
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

  let construct = (~mappings, ~queryCommandTopic, self, name) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let mapIncomingCommands = Mapper.mapIncomingCommands(mappings);
    let mapOutgoingEvent = Mapper.mapOutgoingEvent(mappings);

    let applyCommandAction =
      fun
      | ExtensionPointMapping.AbstractPublishCommand(aggregateName, cmdJson) =>
        cmdJson
        |> Js.Json.stringify
        |> AwsSdk.SQS.sendMessage(
             ~queueId=queryCommandTopic(aggregateName)##id->Pulumi.Output.get,
             ~messageBody=_,
             (),
           )
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on publish command:")
             |> Js.Promise.resolve
           )
      | AbstractCall(handler) =>
        handler()
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on calling handler:")
             |> Js.Promise.resolve
           );

    let eventTopic = EventTopic.make(~opts, ());

    let applyEventAction =
      fun
      | ExtensionPointMapping.AbstractPublishEvent(event') => {
          let publish = eventTopic##publish;
          publish(. [|event'|])
          |> Js.Promise.catch(err =>
               err
               |> Js.log2("ExtensionPoint: Error on publish command:")
               |> Js.Promise.resolve
             );
        }
      | AbstractCall(handler) =>
        handler()
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on calling handler:")
             |> Js.Promise.resolve
           );

    let eventHandler =
      (. event'Json) =>
        event'Json->mapOutgoingEvent->Belt.Array.map(applyEventAction)
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());

    let commandsHandler =
      (. _id, cmds'Json) =>
        cmds'Json->mapIncomingCommands->Belt.Array.map(applyCommandAction)
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());

    let commandTopic = CommandTopic.make(~commandsHandler, ~opts, ());

    makeOutputs(
      ~name,
      ~aggregateNames=
        mappings->Belt.Array.map(((module Mapping)) => Mapping.aggregateName),
      ~eventHandler,
      ~commandTopic,
      ~eventTopic,
    )
    |> self->setOutputs;
  };

  let make: array(module Mapping) => maker =
    (mappings, ~queryCommandTopic, ~opts, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~mappings, ~queryCommandTopic),
        ~opts,
      );
};
