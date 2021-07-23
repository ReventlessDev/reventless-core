let componentType = ComponentType.SideEffectHandler;

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
};

type sideEffectHandler; // TODO: rename back to t - after refactoring
type sideEffectHandlerComponent = Component.t(sideEffectHandler, outputs);

type sideEffects = array(module ReventlessSpec.SideEffect.T);

type maker =
  (
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
    ~memorySize: int,
    ~timeout: int=?,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    unit
  ) =>
  sideEffectHandlerComponent;

type make = (~name: string, ~sideEffects: sideEffects) => maker;

module type T = {let make: make;};

module Make = (EventCollector: EventCollector.T) : T => {
  type constructed;
  type construct = sideEffectHandlerComponent => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    sideEffectHandlerComponent =
    "default";

  [@bs.obj]
  external makeOutputs:
    (~eventCollector: Reventless.EventCollector.outputs, ~name: string) =>
    outputs =
    "";
  [@bs.send]
  external registerOutputs:
    (sideEffectHandlerComponent, outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (sideEffectHandlerComponent, outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let findSideEffect = (sideEffects, eventObj) => {
    eventObj->Belt.Option.flatMapU((. eventObj') => {
      let meta =
        eventObj'->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode);

      switch (meta) {
      | Some(Belt.Result.Ok(eventMeta)) =>
        let sideEffect =
          sideEffects->Belt.Array.getBy(
            (module SideEffect: ReventlessSpec.SideEffect.T) =>
            SideEffect.Source.name == eventMeta.service
          );
        switch (sideEffect) {
        | None =>
          Js.log2(
            "SideEffects.map: No sideEffect available for service:",
            eventMeta.service,
          );
          None;
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
      let count = events'Json->Belt.Array.size;
      events'Json
      ->Belt.Array.mapWithIndex((idx, event'Json) => {
          event'Json->Message.logEvent'Json(
            {j|SideEffectHandler: incoming event $idx/$count:|j},
          );
          let event' = event'Json->Js.Json.decodeObject;
          switch (findSideEffect(sideEffects, event')) {
          | Some((eventObj, eventMeta, sideEffect)) =>
            module SideEffect = (val sideEffect);

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
          };
        })
      ->Js.Promise.all
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
    };

  let construct =
      (
        ~name,
        ~sideEffects,
        ~queryEngine,
        ~queryEventTopic,
        ~memorySize,
        ~timeout,
        self,
      ) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );
    let eventCollector =
      EventCollector.make(
        ~name,
        ~aggregateNames=
          sideEffects->Belt.Array.map(
            (module SideEffect: ReventlessSpec.SideEffect.T) =>
            SideEffect.Source.name
          ),
        ~eventsHandler=eventsHandler(sideEffects, queryEngine),
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
      ~name: string,
      ~sideEffects: array(module ReventlessSpec.SideEffect.T),
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      ~queryEventTopic: InterstackResourceQuery.deploytimeQueryExn,
      ~memorySize: int,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      unit
    ) =>
    sideEffectHandlerComponent =
    (
      ~name,
      ~sideEffects,
      ~queryEngine,
      ~queryEventTopic,
      ~memorySize,
      ~timeout=180,
      ~opts,
      _unit,
    ) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name,
        ~construct=
          construct(
            ~name,
            ~sideEffects,
            ~queryEngine,
            ~queryEventTopic,
            ~memorySize,
            ~timeout,
          ),
        ~opts,
      );
    };
};
