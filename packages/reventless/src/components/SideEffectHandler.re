open ReventlessSpec.Adapter;

module ReventlessEventCollector = EventCollector;

let componentType = ComponentType.SideEffectHandler;

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
};

type sideEffects = array(module ReventlessSpec.SideEffect.T);

module type T = {
  type t;
  let make:
    (
      ~name: string,
      ~sideEffects: sideEffects,
      ~allEventTopics: Js.Dict.t(EventTopic.outputs),
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      ~scheduler: Scheduler.t,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~policy1: Pulumi.Output.t(string)=?,
      ~policy2: Pulumi.Output.t(string)=?,
      ~opts: Pulumi.CustomResourceOptions.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let enqueueEvent: Component.t(t, outputs) => EventCollector.enqueueEvent;
  let createSchedule:
    Component.t(t, outputs) => ReventlessSpec.Schedule.create;
  let deleteSchedule:
    Component.t(t, outputs) => ReventlessSpec.Schedule.delete;
};

module Make = (EventCollector: EventCollector.T) : T => {
  type t;
  type constructed;
  type construct =
    (Component.t(t, outputs), string, resources) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs:
    (~name: string, ~eventCollector: ReventlessEventCollector.outputs) =>
    outputs =
    "";
  [@bs.send]
  external registerOutputs: (Component.t(t, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(t, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set]
  external setEnqueueEvent:
    (Component.t(t, outputs), ReventlessEventCollector.enqueueEvent) => unit =
    "enqueueEvent";
  [@bs.get]
  external enqueueEvent:
    Component.t(t, outputs) => ReventlessEventCollector.enqueueEvent =
    "enqueueEvent";

  [@bs.set]
  external setCreateSchedule:
    (Component.t(t, outputs), ReventlessSpec.Schedule.create) => unit =
    "createSchedule";
  [@bs.get]
  external createSchedule:
    Component.t(t, outputs) => ReventlessSpec.Schedule.create =
    "createSchedule";

  [@bs.set]
  external setDeleteSchedule:
    (Component.t(t, outputs), ReventlessSpec.Schedule.delete) => unit =
    "deleteSchedule";
  [@bs.get]
  external deleteSchedule:
    Component.t(t, outputs) => ReventlessSpec.Schedule.delete =
    "deleteSchedule";

  let findSideEffect = (sideEffects, event'Json) => {
    event'Json
    ->Js.Json.decodeObject
    ->Belt.Option.flatMapU((. eventObj') => {
        let meta =
          eventObj'
          ->Js.Dict.get("meta")
          ->Belt.Option.map(Message.meta_decode);

        switch (meta) {
        | Some(Belt.Result.Ok(eventMeta)) =>
          let sideEffect =
            sideEffects->Belt.Array.getBy(
              (module SideEffect: ReventlessSpec.SideEffect.T) =>
              SideEffect.Source.name == eventMeta.service
            );
          switch (sideEffect) {
          | None => None
          | Some(sideEffect) => Some((eventObj', eventMeta, sideEffect))
          };
        | Some(Error(err)) =>
          Js.log2("SideEffects.map: Couldn't decode meta:", err);
          None;
        | _ =>
          Js.log("SideEffects.map: Invalid JSON object");
          None;
        };
      });
  };

  let eventsHandler = (sideEffects, queryEngine) =>
    (. events'Json) => {
      events'Json
      ->Belt.Array.map(event'Json =>
          switch (sideEffects->findSideEffect(event'Json)) {
          | Some((eventObj, eventMeta, sideEffect)) =>
            module SideEffect = (val sideEffect);
            let sourceName = SideEffect.Source.name;
            event'Json->Message.logEvent'Json(
              {j|SideEffectHandler.eventsHandler: handling event from source $sourceName:|j},
            );
            let idDecoded =
              eventObj
              ->Js.Dict.get("id")
              ->Belt.Option.map(SideEffect.Source.Id.t_decode);
            let eventDecoded =
              eventObj
              ->Js.Dict.get("event")
              ->Belt.Option.map(SideEffect.Source.event_decode);

            switch (idDecoded, eventDecoded) {
            | (Some(Ok(eventId)), Some(Ok(event))) =>
              SideEffect.execute(. eventId, eventMeta, event, queryEngine)
              ->Js.Promise.catch(
                  err =>
                    Js.log2("SideEffect: Error while processing:", err)
                    ->Js.Promise.resolve,
                  _,
                )
            | (None, _)
            | (_, None) =>
              Js.Promise.resolve(
                Js.log("SideEffectHandler.eventHandler: Invalid event"),
              )
            | (_, Some(Error(err)))
            | (Some(Error(err)), _) =>
              Js.Promise.resolve(
                Js.log2(
                  "SideEffectHandler.eventHandler: Couldn't decode event:",
                  err,
                ),
              )
            };
          | None => Js.Promise.resolve()
          }
        )
      ->Js.Promise.all
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
    };

  let construct =
      (
        ~sideEffects,
        ~allEventTopics,
        ~queryEngine,
        ~scheduler: Scheduler.t,
        ~memorySize,
        ~timeout,
        ~policy1=?,
        ~policy2=?,
        self,
        name,
        resources,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let createScheduleFn =
      (. schedule: ReventlessSpec.Schedule.schedule) =>
        (
          Schedule.create(
            scheduler,
            resources->Util.EventCollector.getConnectorResource(name),
          )
        )(.
          schedule,
        );

    let deleteScheduleFn =
      (. scheduleName) =>
        (
          Schedule.delete(
            scheduler,
            resources->Util.EventCollector.getConnectorResource(name),
          )
        )(.
          scheduleName,
        );

    let aggregateNames =
      sideEffects
      ->Belt.Array.map((module SideEffect: ReventlessSpec.SideEffect.T) =>
          SideEffect.Source.name
        )
      ->Belt.Set.String.fromArray;

    let eventsHandler = eventsHandler(sideEffects, queryEngine);
    let eventCollector =
      EventCollector.make(
        ~name,
        ~eventTopics=
          Util.EventTopic.findEventTopics(allEventTopics, aggregateNames),
        ~eventsHandler,
        ~memorySize,
        ~timeout,
        ~policy1?,
        ~policy2?,
        ~opts=Some(opts),
        ~resources,
        (),
      );

    let enqueueEventFn =
      (. delay, id, message) =>
        eventCollector->EventCollector.enqueueEvent(. delay, id, message);

    self->setEnqueueEvent(enqueueEventFn);
    self->setCreateSchedule(createScheduleFn);
    self->setDeleteSchedule(deleteScheduleFn);

    makeOutputs(
      ~name,
      ~eventCollector=eventCollector->Component.extractOutputs,
    )
    ->setOutputs(self, _);
  };

  let make =
      (
        ~name,
        ~sideEffects,
        ~allEventTopics,
        ~queryEngine,
        ~scheduler,
        ~memorySize=2048,
        ~timeout=180,
        ~policy1=?,
        ~policy2=?,
        ~opts=?,
        ~resources,
        _,
      ) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=
        construct(
          ~sideEffects,
          ~allEventTopics,
          ~queryEngine,
          ~scheduler,
          ~memorySize,
          ~timeout,
          ~policy1?,
          ~policy2?,
        ),
      ~opts=
        opts->Belt.Option.map(
          Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
        ),
      ~resources,
    );
  };
};
