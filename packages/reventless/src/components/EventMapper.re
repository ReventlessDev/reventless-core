open ReventlessSpec.Adapter;

let componentType = ComponentType.EventMapper;

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
  "counter": option(Counter.outputs),
};

type eventMapper;
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
  module type Counter = Counter.T with module Target = Target;
  module type Mapping =
    ReventlessSpec.EventMapping.T with module Target := Target;
  let make: (~counter: (module Counter)=?, array(module Mapping)) => maker;
};

module Make =
       (
         Target: ReventlessSpec.EventMapping.Target,
         EventCollector: EventCollector.T,
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
    (
      ~name: string,
      ~eventCollector: Reventless.EventCollector.outputs,
      ~counter: option(Counter.outputs)
    ) =>
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

  module type Counter = Counter.T with module Target = Target;

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

  let makeEntry = (idx, commandId, meta: Message.meta, command, delay) => {
    let commandMeta: Message.meta = {
      ...meta,
      service,
      correlationId:
        // original correlationId only for first action to avoid counting problems
        // TODO: think about different solution, e.g. Counter with explicit
        // count parameter (instead of always counting by 1)
        idx == 0 ? meta.correlationId : Message.uuid(),
      msgId: Message.uuid(),
      time: Message.nowAsISOString(),
    };
    let commandStr = command->Target.command_encode->Js.Json.stringify;
    let source = meta.service;
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

  type action =
    | Counter(Counter.action)
    | Publisher(Js.Promise.t(array(AwsSdk.SQS.SendMessageBatchEntry.t)));

  let processMappingActions = (actions, meta) =>
    actions->Belt.Array.mapWithIndex((idx, action) =>
      switch (action) {
      | ReventlessSpec.EventMapping.Publish(commandId, command) =>
        [|makeEntry(idx, commandId, meta, command, None)|]
        ->Js.Promise.resolve
        ->Publisher
      | PublishDelayed(commandId, command, delay) =>
        [|makeEntry(idx, commandId, meta, command, Some(delay))|]
        ->Js.Promise.resolve
        ->Publisher
      | PublishAsync(promise) =>
        promise
        ->Js.Promise.then_(
            cmds =>
              cmds
              ->Belt.Array.map(((commandId, command)) =>
                  makeEntry(0, commandId, meta, command, None)
                )
              ->Js.Promise.resolve,
            _,
          )
        ->Publisher
      | SetCounterTarget(counterTarget) =>
        SetCounterTarget(counterTarget)->Counter
      | Count(countItem) => Count(countItem)->Counter
      }
    );

  let sendEntries = (entries, resources) =>
    entries
    ->Js.Promise.then_(
        entries =>
          entries->AwsSdk.SQS.sendMessageBatch(
            ~queueId=
              resources->Util.Aggregate.commandTopicConnectorResource(service)##id
              ->Pulumi.Output.get,
          ),
        _,
      )
    ->Js.Promise.catch(
        err => {
          Js.log2(__MODULE__ ++ ".sendEntries error", err);
          Js.Exn.raiseError(__MODULE__ ++ ".sendEntries error");
        },
        _,
      );

  let commonEventsHandler = (mappings, queryEngine, events'Json) => {
    let count = events'Json->Belt.Array.size;
    let (publisherActions, counterActions) =
      events'Json
      ->Belt.Array.mapWithIndex((idx, event'Json) => {
          let idx = idx + 1;
          event'Json->Message.logEvent'Json(
            {j|EventMapper.eventsHandler: incoming event $idx/$count:|j},
          );
          let event' = event'Json->Js.Json.decodeObject;
          switch (findMapping(mappings, event')) {
          // TODO: support multiple mappings for the same source
          | Some((eventObj, eventMeta, mapping)) =>
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
              ->processMappingActions(eventMeta)
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
      ->Belt.Array.partition(resultType =>
          switch (resultType) {
          | Publisher(_) => true
          | Counter(_) => false
          }
        );
    let publisherEntries =
      publisherActions
      ->Belt.Array.map(
          fun
          | Publisher(entries) => entries
          | Counter(_) => Js.Exn.raiseError("Invalid EventMapper action"),
        )
      ->Js.Promise.all
      ->Js.Promise.then_(
          entries => entries->Belt.Array.concatMany->Js.Promise.resolve,
          _,
        );
    let counterActions =
      counterActions->Belt.Array.map(
        fun
        | Counter(action) => action
        | Publisher(_) => Js.Exn.raiseError("Invalid EventMapper action"),
      );
    (publisherEntries, counterActions);
  };

  let eventCollectorEventsHandler =
      (
        resources,
        mappings,
        queryEngine,
        count: Counter.count,
        setCounterTarget: Counter.setCounterTarget,
      ) =>
    (. events'Json) => {
      let (publisherEntries, counterActions) =
        commonEventsHandler(mappings, queryEngine, events'Json);
      let (countActions, setTargetActions) =
        counterActions->Belt.Array.partition(
          fun
          | Counter.Count(_) => true
          | SetCounterTarget(_) => false,
        );

      let countP =
        count(
          countActions->Belt.Array.keepMap(
            fun
            | Count(countItem) => Some(countItem)
            | _ => None,
          ),
        );
      let setTargetActionsP =
        setTargetActions
        ->Belt.Array.map(
            fun
            | SetCounterTarget(counterTarget) =>
              counterTarget->setCounterTarget
            | _ => Js.Promise.resolve(),
          )
        ->Js.Promise.all;

      (countP, setTargetActionsP, sendEntries(publisherEntries, resources))
      ->Js.Promise.all3
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
    };

  let counterEventsHandler = (resources, mappings, queryEngine) =>
    (. events'Json) => {
      let (publisherEntries, countActions) =
        commonEventsHandler(mappings, queryEngine, events'Json);
      if (countActions->Belt.Array.size > 0) {
        Js.log("Counter actions are not allowed in Count mapping!");
      };
      publisherEntries->sendEntries(resources);
    };

  let construct =
      (
        ~counter: option(module Counter),
        ~mappings: array(module Mapping),
        ~queryEngine,
        ~memorySize,
        ~timeout,
        self,
        name,
        resources,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let (count, setCounterTarget, counterOutputs) =
      counter->Belt.Option.mapWithDefault(
        (
          _items => {
            Js.log("No counter deployed, but trying to use counter.")
            ->Js.Promise.resolve;
          },
          _target => {
            Js.log("No counter deployed, but trying to use counter.")
            ->Js.Promise.resolve;
          },
          None,
        ),
        (module Counter: Counter) => {
          let counter =
            Counter.make(
              ~name,
              ~counterEventsHandler=
                counterEventsHandler(resources, mappings, queryEngine),
              ~opts,
              ~resources,
              (),
            );
          (
            counter->Counter.count,
            counter->Counter.setCounterTarget,
            counter->Component.extractOutputs->Some,
          );
        },
      );

    let eventCollector =
      EventCollector.make(
        ~name=Target.name->ComponentType.name(componentType),
        ~aggregateNames=
          mappings->Belt.Array.map((module Mapping: Mapping) =>
            Mapping.Source.name
          ),
        ~eventsHandler=
          eventCollectorEventsHandler(
            resources,
            mappings,
            queryEngine,
            count,
            setCounterTarget,
          ),
        ~memorySize,
        ~timeout,
        ~opts=Some(opts),
        ~resources,
        (),
      );

    makeOutputs(
      ~name,
      ~eventCollector=eventCollector->Component.extractOutputs,
      ~counter=counterOutputs,
    )
    ->setOutputs(self, _);
  };

  let make:
    (
      ~counter: (module Counter)=?,
      array(module Mapping),
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      ~memorySize: int,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources,
      unit
    ) =>
    Component.t(eventMapper, outputs) =
    (
      ~counter=?,
      mappings,
      ~queryEngine,
      ~memorySize,
      ~timeout=180,
      ~opts,
      ~resources,
      _,
    ) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Target.name,
        ~construct=
          construct(~mappings, ~counter, ~queryEngine, ~memorySize, ~timeout),
        ~opts,
        ~resources,
      );
    };
};
