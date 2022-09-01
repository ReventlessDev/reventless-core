open ReventlessSpec.Adapter;

module ReventlessCommandTopic = CommandTopic;
module ReventlessEventTopic = EventTopic;

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
type t;
type component = Component.t(t, outputs);

type name = string;

type maker =
  (
    ~scheduler: Scheduler.t,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~resources: resources,
    unit
  ) =>
  component;

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

module type T = {let make: maker;};

module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec;
  module type Mapping =
    ExtensionPointMapping.T with module ExtensionPoint := Spec;
  let mappings: array(module Mapping);
};

module Make =
       (
         Spec: ReventlessSpec.ExtensionPointMapping.Spec,
         Mappings: Mappings with module Spec := Spec,
         CommandTopicAdapter: CommandTopic.Adapter.Connector,
         EventTopicAdapter: EventTopic.Adapter.Publisher,
       )
       : T => {
  module Spec = Spec;

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
      ~aggregateNames: array(string),
      ~outgoingEventHandler: (. Js.Json.t, PluginSpec.pluginDefinition) =>
                             Js.Promise.t(unit),
      ~commandTopic: ReventlessCommandTopic.outputs,
      ~eventTopic: ReventlessEventTopic.outputs
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

    let mapIncomingCommands =
        (topicItems, mappings, scheduler, queryEngine, queue) =>
      mappings
      ->Belt.Array.map((module Mapping: Mappings.Mapping) =>
          Mapping.mapIncomingCommands(
            topicItems,
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

  let construct = (~scheduler, ~queryEngine, self, name, resources) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let childName =
      name->Js.String2.replace(".", "")->ComponentType.name(componentType);

    let commandTopic:
      ref(
        option(Component.t(CommandTopic.t, ReventlessCommandTopic.outputs)),
      ) =
      ref(None);

    let applyCommandAction =
      fun
      | ExtensionPointMapping.AbstractPublishCommand(
          aggregateName,
          id,
          reference,
          cmdJson,
        ) =>
        cmdJson
        ->Js.Json.stringify // TODO: move to Adapter
        ->AwsSdk.SQS.sendMessage(
            ~queueId=
              resources->Util_Aggregate.commandTopicConnectorResource(
                aggregateName,
              )##id
              ->Pulumi.Output.get,
            ~messageGroupId=id,
            ~messageBody=_,
            (),
          )
        ->Js.Promise.then_(
            _ => Belt.Result.Ok(reference)->Js.Promise.resolve,
            _,
          )
        ->Js.Promise.catch(
            err => {
              Js.log2("ExtensionPoint: Error on publish command:", err);
              Belt.Result.Error(reference)->Js.Promise.resolve;
            },
            _,
          )
      | AbstractCall(reference, handler) =>
        handler()
        ->Js.Promise.then_(
            _ => Belt.Result.Ok(reference)->Js.Promise.resolve,
            _,
          )
        ->Js.Promise.catch(
            err => {
              err->Js.log2("ExtensionPoint: Error on calling handler:");
              Belt.Result.Error(reference)->Js.Promise.resolve;
            },
            _,
          );

    let eventTopic = EventTopic.make(~name=childName, ~opts, ~resources, ());

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
        let queue = commandTopic->Component.extractOutputs##resources[0]; // FIXME: hardcoded resource
        let eventActions =
          event'Json->Mapper.mapOutgoingEvent(
            Mappings.mappings,
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
      (. topicItems) => {
        let commandTopic = (commandTopic^)->Belt.Option.getExn;
        let queue = commandTopic->Component.extractOutputs##resources[0]; // FIXME: hardcoded resource
        let commandActions =
          topicItems->Mapper.mapIncomingCommands(
            Mappings.mappings,
            scheduler,
            queryEngine,
            queue,
          );

        commandActions->Belt.Array.map(applyCommandAction)->Js.Promise.all;
      };

    commandTopic :=
      Some(
        CommandTopic.make(
          ~name=childName,
          ~commandsHandler=incomingCommandsHandler,
          ~opts,
          ~resources,
          (),
        ),
      );

    makeOutputs(
      ~name,
      ~aggregateNames=
        Mappings.mappings->Belt.Array.map(((module Mapping)) =>
          Mapping.aggregateName
        ),
      ~outgoingEventHandler,
      ~commandTopic=
        (commandTopic^)->Belt.Option.getExn->Component.extractOutputs,
      ~eventTopic=eventTopic->Component.extractOutputs,
    )
    ->setOutputs(self, _);
  };

  let make: maker =
    (~scheduler, ~queryEngine, ~opts, ~resources, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct=construct(~scheduler, ~queryEngine),
        ~opts,
        ~resources,
      );
};
