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
  module type Counter = AtomicCounter.T with module Target = Target;
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

  module type Counter = AtomicCounter.T with module Target = Target;

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
        // TODO: think about different solution, e.g. AtomicCounter with explicit
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

  let processActions = (actions, meta) =>
    actions->Belt.Array.mapWithIndex((idx, action) =>
      switch (action) {
      | ReventlessSpec.EventMapping.Publish(commandId, command) =>
        [|makeEntry(idx, commandId, meta, command, None)|]
        ->Js.Promise.resolve
      | PublishDelayed(commandId, command, delay) =>
        [|makeEntry(idx, commandId, meta, command, Some(delay))|]
        ->Js.Promise.resolve
      | PublishAsync(promise) =>
        promise->Js.Promise.then_(
                   cmds =>
                     cmds
                     ->Belt.Array.map(((commandId, command)) =>
                         makeEntry(0, commandId, meta, command, None)
                       )
                     ->Js.Promise.resolve,
                   _,
                 )
      | SetCounterTarget(counterTarget) => Js.Promise.resolve([||])
      | Count(countItem) => Js.Promise.resolve([||])
      }
    );

  let eventsHandler = (resources, mappings, queryEngine) =>
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
              ->processActions(eventMeta)
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

    let (counterMappings, mappings) =
      mappings->Belt.Array.partition(mapping => {
        module Mapping = (val mapping);
        Mapping.Source.name == AtomicCounter.Source.name;
      });

    // let counterMappings =
    //   counterMappings->Belt.Array.map(counterMapping => {
    //     module CounterMapping = (val counterMapping);
    //     module X: AtomicCounter.Mapping = {
    //       module Source: ReventlessSpec.EventMapping.Source = CounterMapping.Source;
    //       let map =
    //         (. id: Source.Id.t, event: Source.event, queryEngine) =>
    //           CounterMapping.map(.
    //             id
    //             ->Source.Id.toString
    //             ->CounterMapping.Source.Id.makeFromString,
    //             event->Obj.magic,
    //             queryEngine,
    //           )
    //           ->Obj.magic;
    //     };
    //     ((module X): (module AtomicCounter.Mapping));
    //     // (module CounterMapping: AtomicCounter.Mapping);
    //   });

    let counterHandler: AtomicCounter.counterHandler =
      (counter, event) =>
        counterMappings
        ->Belt.Array.map(counterMapping => {
            module CounterMapping:
              Mapping with module Source = AtomicCounter.Source = (
              val counterMapping
            );
            CounterMapping.map(. counter, event, queryEngine);
          })
        ->Belt.Array.concatMany;

    let counter =
      counter->Belt.Option.map(counter => {
        module Counter = (val counter);
        Some(Counter.make(~counterHandler, ~opts, ~resources));
      });

    let eventCollector =
      EventCollector.make(
        ~name=Target.name->ComponentType.name(componentType),
        ~aggregateNames=
          mappings->Belt.Array.map((module Mapping: Mapping) =>
            Mapping.Source.name
          ),
        ~eventsHandler=
          eventsHandler(counter, resources, mappings, queryEngine),
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
          construct(
            ~mappings,
            ~counter?,
            ~queryEngine,
            ~memorySize,
            ~timeout,
          ),
        ~opts,
        ~resources,
      );
    };
};
