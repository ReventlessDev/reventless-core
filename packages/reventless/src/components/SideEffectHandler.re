open ReventlessSpec.Adapter;

let componentType = ComponentType.SideEffectHandler;

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
  "eventsHandler": EventCollector.eventsHandler,
};

type sideEffects = array(module ReventlessSpec.SideEffect.T);

module type T = {
  type t;
  let make:
    (
      ~name: string,
      ~sideEffects: sideEffects,
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      ~memorySize: int=?,
      ~timeout: int=?,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);
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
    (
      ~name: string,
      ~eventCollector: Reventless.EventCollector.outputs,
      ~eventsHandler: Reventless.EventCollector.eventsHandler
    ) =>
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
            Js.log3(
              "SideEffectHandler.eventsHandler: handling event from source:",
              SideEffect.Source.name,
              eventObj,
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
          };
        })
      ->Js.Promise.all
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
    };

  let construct =
      (
        ~sideEffects,
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
    let eventsHandler = eventsHandler(sideEffects, queryEngine);
    let eventCollector =
      EventCollector.make(
        ~name=name->ComponentType.name(componentType),
        ~aggregateNames=
          sideEffects->Belt.Array.map(
            (module SideEffect: ReventlessSpec.SideEffect.T) =>
            SideEffect.Source.name
          ),
        ~eventsHandler,
        ~memorySize,
        ~timeout,
        ~opts=Some(opts),
        ~resources,
        (),
      );

    makeOutputs(
      ~name,
      ~eventCollector=eventCollector->Component.extractOutputs,
      ~eventsHandler,
    )
    ->setOutputs(self, _);
  };

  let make =
      (
        ~name,
        ~sideEffects,
        ~queryEngine,
        ~memorySize=2048,
        ~timeout=180,
        ~opts,
        ~resources,
        _,
      ) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~sideEffects, ~queryEngine, ~memorySize, ~timeout),
      ~opts,
      ~resources,
    );
  };
};
