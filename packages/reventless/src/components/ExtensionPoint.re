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

module type T = {
  module Spec: ExtensionPointSpec.T;
  let make:
    (
      ~mappings: array(
                   module ExtensionPointMapping.T with
                     type ExtensionPointSpec.event = Spec.event and
                     type ExtensionPointSpec.command = Spec.command,
                 )
    ) =>
    maker;
};

module Make =
       (
         Spec: Message.Service with module Id = Id.String,
         EventCollector: EventCollector.T,
         CommandTopic:
           CommandTopic.T with
             type id := Spec.id and type command := Spec.command,
         EventTopic:
           EventTopic.T with type id = Spec.id and type event := Spec.event,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;
  module type Mapping =
    ExtensionPointMapping.T with
      type ExtensionPointSpec.event = Spec.event and
      type ExtensionPointSpec.command = Spec.command;

  type eventCollector = Reventless.EventCollector.t;
  type commandTopic = CommandTopic.t;
  type eventTopic = EventTopic.t;

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
      ~eventCollector: eventCollector,
      ~commandTopic: commandTopic,
      ~eventTopic: eventTopic
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
          Mapping.Aggregate.name == aggregateName
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
          commands':
            array(Message.command'(ExtensionPointSpec.id, Spec.command)),
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
            Mapping.Aggregate.name
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

  let make:
    (
      ~mappings: array(
                   module ExtensionPointMapping.T with
                     type ExtensionPointSpec.event = Spec.event and
                     type ExtensionPointSpec.command = Spec.command,
                 )
    ) =>
    maker =
    (~mappings, ~queryCommandTopic, ~queryEventTopic, ~opts, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name->ComponentType.name(componentType),
        ~construct=construct(~mappings, ~queryCommandTopic, ~queryEventTopic),
        ~opts,
      );
};

// module MakeSpec = (ExtensionPoint: ExtensionPointSpec.T) => {
//   let name = ExtensionPoint.name;

//   module Id = Id.String;

//   [@decco]
//   type id = Id.t;

//   type command = ExtensionPoint.command;
//   let command_encode = ExtensionPoint.command_encode;
//   let command_decode = ExtensionPoint.command_decode;

//   type event = ExtensionPoint.event;
//   let event_encode = ExtensionPoint.event_encode;
//   let event_decode = ExtensionPoint.event_decode;

//   [@decco]
//   type error = unit;
// };

/*
 module MakeSpec =
        (ExtensionPoint: ExtensionPointSpec.T)

          : (
            Message.Service with
              module Id = Id.String and type id = ExtensionPointSpec.id
        ) => {
   include ExtensionPoint;

   module Id = Id.String;
   [@decco]
   type id = Id.t;

   [@decco]
   type error = unit;
 };

 let make =
     (
       ~spec: (module Message.Service),
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

   ExtensionPoint.make;
 };
 */
