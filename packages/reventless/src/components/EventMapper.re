open ReventlessSpec.Adapter;

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
    ~memorySize: int,
    ~timeout: int=?,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~resources: resources,
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
         AtomicCounter: AtomicCounter.T,
       )
       : (T with module Target := Target) => {
  type constructed;
  type construct =
    (Component.t(eventMapper, outputs), string, resources) => constructed;

  module type Mapping =
    ReventlessSpec.EventMapping.T with module Target := Target;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources
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

  let eventsHandler = (atomicCounter, resources, mappings, queryEngine) =>
    (. events'Json) => {
      let count = events'Json->Belt.Array.size;
      events'Json
      ->Belt.Array.mapWithIndex((idx, event'Json) => {
          let idx = idx + 1;
          event'Json->Message.logEvent'Json(
            {j|EventMapper.eventsHandler: incoming event $idx/$count:|j},
          );
          let event' = event'Json->Js.Json.decodeObject;
          switch (findMapping(mappings, event')) {
          | Some((eventObj, eventMeta, mapping)) =>
            let makeEntry = (idx, commandId, command, delay) => {
              let commandMeta = {
                ...eventMeta,
                service,
                correlationId:
                  // original correlationId only for first action to avoid counting problems
                  // TODO: think about different solution, e.g. AtomicCounter with explicit
                  // count parameter (instead of always counting by 1)
                  idx == 0 ? eventMeta.correlationId : Message.uuid(),
                msgId: Message.uuid(),
                time: Message.nowAsISOString(),
              };
              let commandStr =
                command->Target.command_encode->Js.Json.stringify;
              let source = eventMeta.service;
              Js.log(
                {j|EventMapping from Aggregate $source to Aggregate $service: Publishing command: $commandStr id: $commandId|j},
              );
              let messageBody =
                Message.command'_encode(
                  Target.Id.t_encode,
                  Target.command_encode,
                  {Message.id: commandId, meta: commandMeta, command},
                )
                ->Js.Json.stringify;
              AwsSdk.SQS.makeBatchEntry(
                ~groupId=commandId->Target.Id.toString,
                ~messageId=commandMeta.msgId,
                ~messageBody,
                ~delay,
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
                    [|makeEntry(idx, commandId, command, None)|]
                    ->Js.Promise.resolve
                  | PublishDelayed(commandId, command, delay) =>
                    [|makeEntry(idx, commandId, command, Some(delay))|]
                    ->Js.Promise.resolve
                  | PublishAsync(promise) =>
                    promise->Js.Promise.then_(
                               cmds =>
                                 cmds
                                 ->Belt.Array.map(((commandId, command)) =>
                                     makeEntry(0, commandId, command, None)
                                   )
                                 ->Js.Promise.resolve,
                               _,
                             )
                  | SetCounterTarget(counterTarget) =>
                    Js.Promise.resolve([||])
                  | Count(countItem) => Js.Promise.resolve([||])
                  }
                )
              ->Some
            | (None, _)
            | (_, None) =>
              Js.log("EventMapper.map: Invalid event");
              None;
            | (_, Some(Error(err)))
            | (Some(Error(err)), _) =>
              Js.log2("EventMapper.map: Couldn't decode event:", err);
              None;
            };
          | None => None
          };
        })
      ->Belt.Array.keepMap(entry => entry)
      ->Belt.Array.concatMany
      ->Js.Promise.all
      ->Js.Promise.then_(
          entries =>
            entries
            ->Belt.Array.concatMany
            ->AwsSdk.SQS.sendMessageBatch(
                ~queueId=
                  resources->Util.Aggregate.commandTopicConnectorResource(
                    service,
                  )##id
                  ->Pulumi.Output.get,
              ),
          _,
        )
      ->Js.Promise.catch(
          err =>
            err
            ->Js.log2("EventMapper: Error on sendMessageBatch:", _)
            ->Js.Promise.resolve,
          _,
        );
    };

  let construct =
      (~mappings, ~queryEngine, ~memorySize, ~timeout, self, name, resources) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let atomicCounter = AtomicCounter.make(~opts, ~resources);

    let eventCollector =
      EventCollector.make(
        ~name=Target.name->ComponentType.name(componentType),
        ~aggregateNames=
          mappings->Belt.Array.map((module Mapping: Mapping) =>
            Mapping.Source.name
          ),
        ~eventsHandler=
          eventsHandler(atomicCounter, resources, mappings, queryEngine),
        ~memorySize,
        ~timeout,
        ~opts=Some(opts),
        ~resources,
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
      ~memorySize: int,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources,
      unit
    ) =>
    Component.t(eventMapper, outputs) =
    (mappings, ~queryEngine, ~memorySize, ~timeout=180, ~opts, ~resources, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Target.name,
        ~construct=construct(~mappings, ~queryEngine, ~memorySize, ~timeout),
        ~opts,
        ~resources,
      );
    };
};
