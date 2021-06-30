let componentType = ComponentType.EventMapper;

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
};

type eventMapper; // TODO: rename back to t - after refactoring
type maker =
  (
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
    ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
    ~memorySize: int,
    ~timeout: int=?,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    unit
  ) =>
  Component.t(eventMapper, outputs);

module type T = {
  module Target: ReventlessSpec.EventMapping.Target;
  module type Mapping =
    ReventlessSpec.EventMapping.T with module Target := Target;
  let make: array(module Mapping) => maker;
};

module Make =
       (
         Target: ReventlessSpec.EventMapping.Target,
         EventCollector: EventCollector.T,
       )
       : (T with module Target := Target) => {
  type constructed;
  type construct = (Component.t(eventMapper, outputs), string) => constructed;

  module type Mapping =
    ReventlessSpec.EventMapping.T with module Target := Target;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    Component.t(eventMapper, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs:
    (~eventCollector: Reventless.EventCollector.outputs, ~name: string) =>
    outputs =
    "";
  [@bs.send]
  external registerOutputs:
    (Component.t(eventMapper, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(eventMapper, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  module Target = Target;

  let service = Target.name;

  let findMapping = (mappings, eventObj) => {
    eventObj->Belt.Option.flatMapU((. eventObj') => {
      let meta =
        eventObj'->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode);

      switch (meta) {
      | Some(Belt.Result.Ok(eventMeta)) =>
        let mapping =
          mappings->Belt.Array.getBy((module Mapping: Mapping) =>
            Mapping.Source.name == eventMeta.service
          );
        switch (mapping) {
        | None =>
          Js.log2(
            "EventMapper.map: No mapping available for service:",
            eventMeta.service,
          );
          None;
        | Some(mapping) => Some((eventObj', eventMeta, mapping))
        };
      | Some(Error(err)) =>
        Js.log2("EventMapper.map: Couldn't decode meta:", err);
        None;
      | _ =>
        Js.log("EventMapper.map: Invalid JSON object");
        None;
      };
    });
  };

  let map = (mappings, queryCommandTopic, queryEngine) =>
    (. event'Json) => {
      event'Json->Message.logEvent'Json("EventMapper.map: incoming event:");
      let event' = event'Json->Js.Json.decodeObject;
      switch (findMapping(mappings, event')) {
      | Some((eventObj, eventMeta, mapping)) =>
        let publish = (idx, commandId, command, delay) => {
          let commandMeta = {
            ...eventMeta,
            service,
            correlationId:
              // original correlationId only for first action to avoid counting problems
              // TODO: think about different solution, e.g. AtomicCounter with explicit
              // count parameter (instead of always counting by 1)
              idx == 0 ? eventMeta.correlationId : Message.uuid(),
            msgId: Message.uuid(),
          };
          let queueId = queryCommandTopic(service)##id->Pulumi.Output.get;
          let commandStr = command->Target.command_encode->Js.Json.stringify;
          let source = eventMeta.service;
          Js.log(
            {j|EventMapping from Aggregate $source to Aggregate $service: Publishing command: $commandStr id: $commandId|j},
          );

          Message.command'_encode(
            Target.Id.t_encode,
            Target.command_encode,
            {Message.id: commandId, meta: commandMeta, command},
          )
          ->Js.Json.stringify
          ->AwsSdk.SQS.sendMessage(
              ~queueId,
              ~messageGroupId=commandId->Target.Id.toString,
              ~messageBody=_,
              ~delay,
              (),
            )
          ->Js.Promise.catch(
              err =>
                err
                ->Js.log2("EventMapper: Error on publish command:")
                ->Js.Promise.resolve,
              _,
            );
        };

        module Mapping = (val mapping);

        let idDecoded =
          eventObj
          ->Js.Dict.get("id")
          ->Belt.Option.map(Mapping.Source.Id.t_decode);
        let eventDecoded =
          eventObj
          ->Js.Dict.get("event")
          ->Belt.Option.map(Mapping.Source.event_decode);

        switch (idDecoded, eventDecoded) {
        | (Some(Ok(eventId)), Some(Ok(event))) =>
          Mapping.map(. eventId, event, queryEngine)
          ->Belt.Array.mapWithIndex((idx, action) =>
              switch (action) {
              | ReventlessSpec.EventMapping.Publish(commandId, command) =>
                publish(idx, commandId, command, 0)
              | PublishDelayed(commandId, command, delay) =>
                publish(idx, commandId, command, delay)
              | PublishAsync(promise) =>
                promise->Js.Promise.then_(
                           cmds =>
                             cmds
                             ->Belt.Array.map(((commandId, command)) =>
                                 publish(idx, commandId, command, 0)
                               )
                             ->Js.Promise.all
                             ->Js.Promise.then_(_ => Js.Promise.resolve(), _),
                           _,
                         )
              }
            )
          ->Js.Promise.all
          ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
        | (None, _)
        | (_, None) =>
          Js.Promise.resolve(Js.log("EventMapper.map: Invalid event"))
        | (_, Some(Error(err)))
        | (Some(Error(err)), _) =>
          Js.Promise.resolve(
            Js.log2("EventMapper.map: Couldn't decode event:", err),
          )
        };
      | None => Js.Promise.resolve()
      };
    };

  let construct =
      (
        ~mappings,
        ~queryEngine,
        ~queryCommandTopic,
        ~queryEventTopic,
        ~memorySize,
        ~timeout,
        self,
        name,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );
    let eventCollector =
      EventCollector.make(
        ~name=Target.name,
        ~aggregateNames=
          mappings->Belt.Array.map((module Mapping: Mapping) =>
            Mapping.Source.name
          ),
        ~eventHandler=map(mappings, queryCommandTopic, queryEngine),
        ~queryEventTopic,
        ~memorySize,
        ~timeout,
        ~opts=Some(opts),
        (),
      );

    makeOutputs(
      ~eventCollector=eventCollector->Component.extractOutputs,
      ~name,
    )
    ->setOutputs(self, _);
  };

  let make:
    (
      array(module Mapping),
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      ~queryCommandTopic: InterstackResourceQuery.runtimeQueryExn,
      ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
      ~memorySize: int,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    Component.t(eventMapper, outputs) =
    (
      mappings,
      ~queryEngine,
      ~queryCommandTopic,
      ~queryEventTopic,
      ~memorySize,
      ~timeout=180,
      ~opts,
      _unit,
    ) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Target.name,
        ~construct=
          construct(
            ~mappings,
            ~queryEngine,
            ~queryCommandTopic,
            ~queryEventTopic,
            ~memorySize,
            ~timeout,
          ),
        ~opts,
      );
    };
};
