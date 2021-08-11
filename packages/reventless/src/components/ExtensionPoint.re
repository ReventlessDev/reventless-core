let componentType = ComponentType.ExtensionPoint;

type outputs = {
  .
  "name": string,
  "aggregateNames": array(string),
  "outgoingEventHandler":
    (. Js.Json.t, PluginSpec.pluginDefinition) => Js.Promise.t(unit),
  "commandTopic": CommandTopic.outputs,
  "eventTopic": EventTopic.outputs,
};
type extensionPoint; // TODO: rename to t - after refactoring

type name = string;

let setCommandTopicConnectorResource = (resource, extensionPointName) =>
  resource->CommandTopic.Adapter.setConnectorResource(
    extensionPointName->ComponentType.name(componentType),
  );
let setEventTopicPublisherResource = (resource, extensionPointName) =>
  resource->EventTopic.Adapter.setPublisherResource(
    extensionPointName->ComponentType.name(componentType),
  );

let commandTopicConnectorResource = extensionPointName =>
  extensionPointName
  ->ComponentType.name(componentType)
  ->CommandTopic.Adapter.getConnectorResource;
let eventTopicPublisherResource = extensionPointName =>
  extensionPointName
  ->ComponentType.name(componentType)
  ->EventTopic.Adapter.getPublisherResource;

let eventTopics = extensionPointNames =>
  extensionPointNames
  ->Belt.Array.map(extensionPointName =>
      (extensionPointName, extensionPointName->eventTopicPublisherResource)
    )
  ->Belt.Array.map(((extensionPointName, topic)) =>
      (topic##service, (extensionPointName, topic))
    );

type maker =
  (
    ~scheduler: Scheduler.t,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    unit
  ) =>
  Component.t(extensionPoint, outputs);

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
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec;
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;
  let make: array(module Mapping) => maker;
};

module Make =
       (
         Spec: ReventlessSpec.ExtensionPointMapping.Spec,
         CommandTopicAdapter: CommandTopic.Adapter.Connector,
         EventTopicAdapter: EventTopic.Adapter.Publisher,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;

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

  type constructed;
  type construct =
    (Component.t(extensionPoint, outputs), string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(extensionPoint, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~name: string,
      ~aggregateNames: array(string),
      ~outgoingEventHandler: (. Js.Json.t, PluginSpec.pluginDefinition) =>
                             Js.Promise.t(unit),
      ~commandTopic: Reventless.CommandTopic.outputs,
      ~eventTopic: Reventless.EventTopic.outputs
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs:
    (Component.t(extensionPoint, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(extensionPoint, outputs), outputs) => unit =
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

    let mapIncomingCommands =
        (commands', mappings, scheduler, queryEngine, queue) =>
      mappings
      ->Belt.Array.map((module Mapping: Mapping) =>
          Mapping.mapIncomingCommands(
            commands',
            Schedule.create(scheduler, queue),
            Schedule.delete(scheduler, queue),
            queryEngine,
          )
        )
      ->Belt.Array.concatMany;

    let mapOutgoingEvent = (event'Json, mappings, scheduler, queue) =>
      switch (
        event'Json->Message.serviceNameOfMsg->findOutgoingMapping(mappings)
      ) {
      | Some((module Mapping)) =>
        Mapping.mapOutgoingEvent(
          event'Json,
          Schedule.create(scheduler, queue),
          Schedule.delete(scheduler, queue),
        )
      | None =>
        Js.Exn.raiseError(
          "ExtensionPoint.Mapping: Missing mapping for "
          ++ event'Json->Js.Json.stringify,
        )
      };
  };

  let construct = (~mappings, ~scheduler, ~queryEngine, self, name) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let childName =
      name->Js.String2.replace(".", "")->ComponentType.name(componentType);

    let commandTopic:
      ref(
        option(Component.t(CommandTopic.t, Reventless.CommandTopic.outputs)),
      ) =
      ref(None);

    let applyCommandAction =
      fun
      | ExtensionPointMapping.AbstractPublishCommand(
          aggregateName,
          id,
          cmdJson,
        ) =>
        cmdJson
        ->Js.Json.stringify
        ->AwsSdk.SQS.sendMessage(
            ~queueId=
              aggregateName->Reventless.Aggregate.commandTopicConnectorResource##id
              ->Pulumi.Output.get,
            ~messageGroupId=id,
            ~messageBody=_,
            (),
          )
        ->Js.Promise.catch(
            err =>
              err
              |> Js.log2("ExtensionPoint: Error on publish command:")
              |> Js.Promise.resolve,
            _,
          )
      | AbstractCall(handler) =>
        handler()
        ->Js.Promise.catch(
            err =>
              err
              ->Js.log2("ExtensionPoint: Error on calling handler:")
              ->Js.Promise.resolve,
            _,
          );

    let eventTopic = EventTopic.make(~name=childName, ~opts, ());

    let applyEventAction =
      fun
      | ExtensionPointMapping.AbstractPublishEvent(event') => {
          let publish = EventTopic.publish(eventTopic);
          publish(. [|event'|])
          ->Js.Promise.catch(
              err =>
                err
                ->Js.log2("ExtensionPoint: Error on publish command:")
                ->Js.Promise.resolve,
              _,
            );
        }
      | ExtensionPointMapping.AbstractPublishEventAsync(promise) => {
          let publish = EventTopic.publish(eventTopic);
          promise->Js.Promise.then_(
                     event' =>
                       publish(. [|event'|])
                       ->Js.Promise.catch(
                           err =>
                             err
                             ->Js.log2(
                                 "ExtensionPoint: Error on publish command:",
                               )
                             ->Js.Promise.resolve,
                           _,
                         ),
                     _,
                   );
        }
      | AbstractCall(handler) =>
        handler()
        ->Js.Promise.catch(
            err =>
              err
              ->Js.log2("ExtensionPoint: Error on calling handler:")
              ->Js.Promise.resolve,
            _,
          );

    let outgoingEventHandler =
      (. event'Json, pluginDef) => {
        let commandTopic = (commandTopic^)->Belt.Option.getExn;
        let queue = commandTopic->Component.extractOutputs##connector;
        let eventActions =
          event'Json->Mapper.mapOutgoingEvent(
            mappings,
            scheduler,
            queue,
            pluginDef,
            queryEngine,
          );

        eventActions->Belt.Array.map(applyEventAction)
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());
      };

    let incomingCommandsHandler =
      (. _id, cmds'Json) => {
        let commandTopic = (commandTopic^)->Belt.Option.getExn;
        let queue = commandTopic->Component.extractOutputs##connector;
        let commandActions =
          cmds'Json->Mapper.mapIncomingCommands(
            mappings,
            scheduler,
            queryEngine,
            queue,
          );

        commandActions->Belt.Array.map(applyCommandAction)
        |> Js.Promise.all
        |> Js.Promise.then_(_ => Js.Promise.resolve());
      };

    commandTopic :=
      Some(
        CommandTopic.make(
          ~name=childName,
          ~commandsHandler=incomingCommandsHandler,
          ~opts,
          (),
        ),
      );

    makeOutputs(
      ~name,
      ~aggregateNames=
        mappings->Belt.Array.map(((module Mapping)) => Mapping.aggregateName),
      ~outgoingEventHandler,
      ~commandTopic=
        (commandTopic^)->Belt.Option.getExn->Component.extractOutputs,
      ~eventTopic=eventTopic->Component.extractOutputs,
    )
    ->setOutputs(self, _);
  };

  let make: array(module Mapping) => maker =
    (mappings, ~scheduler, ~queryEngine, ~opts, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~mappings, ~scheduler, ~queryEngine),
        ~opts,
      );
};
