module ReventlessEventCollector = EventCollector;

let componentType = ComponentType.EventMapper;

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
  "counter": option(Counter.outputs),
};

type t;
type component = Component.t(t, outputs);

module type T = {
  let make:
    (
      ~allEventTopics: EventTopic.allOutputs,
      ~allQueryDbs: QueryDb.allOutputs,
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      ~publishJsons: CommandTopic.publishJsons,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    component;
};

module type Mappings = {
  module Target: ReventlessSpec.EventMapping.Target;
  module type Mapping =
    ReventlessSpec.EventMapping.T with module Target := Target;
  let mappings: array(module Mapping);
  let counter: option(module Counter.T);
};

module Make =
       (
         Target: ReventlessSpec.EventMapping.Target,
         EventCollector: EventCollector.T,
         Mappings: Mappings with module Target := Target,
       )
       : T => {
  type constructed;
  type construct = (component, string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    component =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~name: string,
      ~eventCollector: ReventlessEventCollector.outputs,
      ~counter: option(Counter.outputs)
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

  module Target = Target;
  let target = Target.name;

  let findMapping = (mappings, eventObj) => {
    eventObj->Belt.Option.flatMapU((. eventObj') => {
      let meta =
        eventObj'->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode);

      switch (meta) {
      | Some(Belt.Result.Ok(eventMeta)) =>
        let source = eventMeta.service;
        let mapping =
          mappings->Belt.Array.getBy((module Mapping: Mappings.Mapping) =>
            Mapping.Source.name == source
          );
        switch (mapping) {
        | None =>
          Js.log({j|EventMapper.map: No mapping $source -> $target found|j});
          None;
        | Some(mapping) =>
          module Mapping = (val mapping);
          let source = Mapping.Source.name;
          Js.log({j|EventMapper.map: found mapping $source -> $target|j});
          Some((eventObj', eventMeta, mapping));
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

  type action =
    | Counter(Counter.action)
    | Publisher(Js.Promise.t(array(Message.commandJson)));

  let createCommandJson = (~delay=?, id, meta, command) => {
    Message.id: id->Target.Id.toString,
    meta: {
      ...meta,
      service: Target.name,
      msgId: Message.uuid(),
      time: Message.nowAsISOString(),
    },
    commandJson: command->Target.command_encode,
    delay,
  };

  let processMappingActions = (actions, eventMeta) =>
    actions->Belt.Array.map(
      fun
      | ReventlessSpec.EventMapping.Publish(id, command) =>
        [|createCommandJson(id, eventMeta, command)|]
        ->Js.Promise.resolve
        ->Publisher
      | PublishDelayed(id, command, delay) =>
        [|createCommandJson(~delay, id, eventMeta, command)|]
        ->Js.Promise.resolve
        ->Publisher
      | PublishAsync(promise) =>
        promise
        ->Js.Promise.then_(
            cmds =>
              cmds
              ->Belt.Array.map(((id, command)) =>
                  createCommandJson(id, eventMeta, command)
                )
              ->Js.Promise.resolve,
            _,
          )
        ->Publisher
      | AddToCounterTarget({counterId, target}) =>
        AddToCounterTarget({
          counterId,
          target,
          targetRef: eventMeta.correlationId,
        })
        ->Counter
      | Count(counterId) =>
        Count({counterId, reference: eventMeta.correlationId, inc: 1})
        ->Counter
      | CountMulti(counterId, inc) =>
        Count({counterId, reference: eventMeta.correlationId, inc})->Counter,
    );

  let commonEventsHandler = (mappings, queryEngine, events'Json) => {
    let eventsCount = events'Json->Belt.Array.size;
    let (publisherActions, counterActions) =
      events'Json
      ->Belt.Array.mapWithIndex((idx, event'Json) => {
          let idx = idx + 1;
          event'Json->Message.logEvent'Json(
            {j|EventMapper.eventsHandler: incoming event $idx/$eventsCount:|j},
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
        publishJsons,
        mappings,
        queryEngine,
        count: Counter.count,
        addToCounterTarget: Counter.addToCounterTarget,
      ) =>
    (. events'Json) => {
      let (publisherEntries, counterActions) =
        commonEventsHandler(mappings, queryEngine, events'Json);
      let (countActions, addToCounterTargetActions) =
        counterActions->Belt.Array.partition(
          fun
          | Counter.Count(_) => true
          | AddToCounterTarget(_) => false,
        );

      let countActions =
        countActions->Belt.Array.keepMap(
          fun
          | Count(countItem) => Some(countItem)
          | _ => None,
        );
      Js.log2(
        "EventMapper.eventCollectorEventsHandler: countActions:",
        countActions->Belt.Array.size,
      );
      let countP =
        switch (countActions->Belt.Array.size) {
        | 0 => Js.Promise.resolve()
        | _ =>
          count(countActions)
          ->Js.Promise.catch(
              err => {
                let error =
                  __MODULE__ ++ ".eventCollectorEventsHandler: count error";
                Js.log2(error, err);
                Js.Exn.raiseError(error);
              },
              _,
            )
        };

      Js.log2(
        "EventMapper.eventCollectorEventsHandler: addToCounterTargetActions:",
        addToCounterTargetActions->Js.Json.stringifyAny,
      );
      let addToCounterTargetsP =
        addToCounterTargetActions
        ->Belt.Array.map(
            fun
            | AddToCounterTarget(counterTarget) =>
              addToCounterTarget(counterTarget)
            | _ => Js.Promise.resolve(),
          )
        ->Js.Promise.all;

      let sendEntriesP =
        publisherEntries
        |> Js.Promise.then_(commandJsons => publishJsons(. commandJsons));

      (countP, addToCounterTargetsP, sendEntriesP)
      ->Js.Promise.all3
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
    };

  let counterEventsHandler = (publishJsons, mappings, queryEngine) =>
    (. events'Json) => {
      let (publisherEntries, countActions) =
        commonEventsHandler(mappings, queryEngine, events'Json);
      if (countActions->Belt.Array.size > 0) {
        Js.log(
          "EventMapper.counterEventsHandler: Counter actions are not allowed in Count mapping!",
        );
      };
      publisherEntries
      |> Js.Promise.then_(commandJsons => publishJsons(. commandJsons));
    };

  let construct =
      (
        ~allEventTopics,
        ~allQueryDbs,
        ~queryEngine,
        ~publishJsons,
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

    let (count, setCounterTarget, counterOutputs) =
      Mappings.counter->Belt.Option.mapWithDefault(
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
        (module Counter: Counter.T) => {
          let counter =
            Counter.make(
              ~name,
              ~counterEventsHandler=
                counterEventsHandler(
                  publishJsons,
                  Mappings.mappings,
                  queryEngine,
                ),
              ~opts,
              ~allQueryDbs,
              (),
            );
          (
            counter->Counter.count,
            counter->Counter.addToCounterTarget,
            counter->Component.extractOutputs->Some,
          );
        },
      );

    module Set = Belt.Set.String;
    let aggregateNames =
      Mappings.mappings
      ->Belt.Array.keepMap((module Mapping: Mappings.Mapping) =>
          if (Mapping.Source.name != Counter.Source.name) {
            Some(Mapping.Source.name);
          } else {
            None;
          }
        )
      ->Set.fromArray;

    let eventCollector =
      EventCollector.make(
        ~name=Target.name->ComponentType.name(componentType),
        ~eventTopics=
          allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
        ~eventsHandler=
          eventCollectorEventsHandler(
            publishJsons,
            Mappings.mappings,
            queryEngine,
            count,
            setCounterTarget,
          ),
        ~memorySize,
        ~timeout,
        ~opts=Some(opts),
        (),
      );

    makeOutputs(
      ~name,
      ~eventCollector=eventCollector->Component.extractOutputs,
      ~counter=counterOutputs,
    )
    ->setOutputs(self, _);
  };

  let make =
      (
        ~allEventTopics,
        ~allQueryDbs,
        ~queryEngine,
        ~publishJsons,
        ~memorySize=128,
        ~timeout=180,
        ~opts=?,
        _,
      ) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Target.name,
      ~construct=
        construct(
          ~allEventTopics,
          ~allQueryDbs,
          ~queryEngine,
          ~publishJsons,
          ~memorySize,
          ~timeout,
        ),
      ~opts,
    );
  };
};
