let componentType = ComponentType.ExtensionPoint;

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
  "commandTopic": CommandTopic.outputs,
  "eventTopic": EventTopic.outputs,
};
type t = outputs;

type name = string;

type maker =
  (
    ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
    ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
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
         EventCollectorAdapter: EventCollector.Connector,
         CommandTopicAdapter: CommandTopic.Connector,
         EventTopicAdapter: EventTopic.Publisher,
       )
       : (T with module Spec := Spec) => {
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;

  module EventCollector =
    EventCollector.Make(EventCollector.NoPolicies, EventCollectorAdapter);

  module SpecWithId:
    Spec with
      type command = Spec.command and
      type event = Spec.event and
      type callCommand = Spec.callCommand = {
    include Spec;
    module Id = Id.String;
  };

  module CommandTopic = CommandTopic.Make(SpecWithId, CommandTopicAdapter);

  module EventTopic = EventTopic.Make(SpecWithId, EventTopicAdapter);

  //type eventCollector = Reventless.EventCollector.t;
  //type commandTopic = CommandTopic.t;
  //type eventTopic = EventTopic.t;

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
      ~eventCollector: Reventless.EventCollector.t,
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

    let aggregateNameOfMsg = msgJson =>
      switch (msgJson->Js.Json.decodeObject) {
      | Some(msgObj) =>
        msgObj->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode)
        |> (
          fun
          | Some(Ok(msgMeta)) => Some(msgMeta.service)
          | Some(Error(err)) => {
              Js.log2("EventMapper.map: Couldn't decode meta:", err);
              None;
            }
          | _ => {
              Js.log("ExtensionPoint.Mapper.map: Invalid JSON object");
              None;
            }
        )
      | None =>
        Js.log2("EventMapper.map: Couldn't decode message:", msgJson);
        None;
      };

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
      switch (event'Json->aggregateNameOfMsg->findOutgoingMapping(mappings)) {
      | Some((module Mapping)) => Mapping.mapOutgoingEvent(event'Json)
      | None =>
        Js.Exn.raiseError(
          "ExtensionPoint.Mapping: Missing mapping for "
          ++ event'Json->Js.Json.stringify,
        )
      };
  };

  let construct =
      (~mappings, ~queryCommandTopic, ~queryEventTopic, self, name) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let mapIncomingCommands = Mapper.mapIncomingCommands(mappings);
    let mapOutgoingEvent = Mapper.mapOutgoingEvent(mappings);

    let applyCommandAction =
      fun
      | ExtensionPointMapping.PublishCommand(aggregateName, cmdJson) =>
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
      | Call(handler, msg) =>
        handler(msg)
        |> Js.Promise.catch(err =>
             err
             |> Js.log2("ExtensionPoint: Error on calling handler:")
             |> Js.Promise.resolve
           );

    let eventTopic = EventTopic.make(~opts, ());

    let applyEventAction =
      fun
      | ExtensionPointMapping.PublishEvent(event') => {
          let publish = eventTopic##publish;
          publish(. [|event'|])
          |> Js.Promise.catch(err =>
               err
               |> Js.log2("ExtensionPoint: Error on publish command:")
               |> Js.Promise.resolve
             );
        }
      | Call(handler, msg) =>
        handler(msg)
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

    let eventCollector =
      EventCollector.make(
        ~name,
        ~aggregateNames=
          mappings->Belt.Array.map(((module Mapping)) =>
            Mapping.aggregateName
          ),
        ~eventHandler,
        ~queryEventTopic,
        ~opts=Some(opts),
        (),
      );

    let commandsHandler =
      (. _id, cmds'Json) =>
        cmds'Json->mapIncomingCommands->Belt.Array.map(applyCommandAction)
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());

    let commandTopic = CommandTopic.make(~commandsHandler, ~opts, ());

    makeOutputs(~name, ~eventCollector, ~commandTopic, ~eventTopic)
    |> self->setOutputs;
  };

  let make: array(module Mapping) => maker =
    (mappings, ~queryCommandTopic, ~queryEventTopic, ~opts, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name->ComponentType.name(componentType),
        ~construct=construct(~mappings, ~queryCommandTopic, ~queryEventTopic),
        ~opts,
      );
};

/*
 let make =
     (
       ~spec: (module ExtensionPointMapping.Spec),
       ~mappings: array(module ExtensionPointMapping.T with
     module ExtensionPoint = Spec),
       ~eventCollectorAdapter: (module EventCollector.Connector),
       ~commandTopicAdapter: (module CommandTopic.Connector),
       ~eventTopicAdapter: (module EventTopic.Publisher),
     ) => {
   module EventCollector =
     EventCollector.Make(
       EventCollector.NoPolicies,
       (val eventCollectorAdapter),
     );
   module Spec = (val spec);
   module CommandTopic = CommandTopic.Make(Spec, (val commandTopicAdapter));
   module EventTopic = EventTopic.Make(Spec, (val eventTopicAdapter));

   module ExtensionPoint =
     Make(Spec, EventCollector, CommandTopic, EventTopic);

   ExtensionPoint.make(~mappings);
 };
 */

/*
 module MakeSimple =
        (
          OriginalSpec: ExtensionPointMapping.Spec,
          EventCollectorAdapter: EventCollector.Connector,
          CommandTopicAdapter: CommandTopic.Connector,
          EventTopicAdapter: EventTopic.Publisher,
        )
        : (T with module Spec := OriginalSpec) => {
   module Spec = {
     include OriginalSpec;
     module Id = Id.String;
   };
   module EventCollector =
     EventCollector.Make(EventCollector.NoPolicies, EventCollectorAdapter);
   module CommandTopic = CommandTopic.Make(Spec, CommandTopicAdapter);
   module EventTopic = EventTopic.Make(Spec, EventTopicAdapter);

   module ExPt = Make(Spec, EventCollector, CommandTopic, EventTopic);

   include ExPt;
 };
 */
