open ReventlessSpec.Adapter;

let componentType = ComponentType.SideEffectHandler;

type publishCommands =
  (
    . /*~queueName:*/ string,
    array((/*~id:*/ string, /*~meta*/ Message.meta, /*~message:*/ string))
  ) =>
  Js.Promise.t(unit);

type queueEvent =
  (. /*~delay:*/ int, /*~id:*/ string, /*~message:*/ string) =>
  Js.Promise.t(unit);

type outputs = {
  .
  "name": string,
  "eventCollector": EventCollector.outputs,
  "queryEngine": ReventlessSpec.QueryEngine.t,
  "publishCommands": publishCommands,
  "queueEvent": queueEvent,
  "createSchedule": ReventlessSpec.Schedule.create,
  "deleteSchedule": ReventlessSpec.Schedule.delete,
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
      ~scheduler: Scheduler.t,
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
      ~queryEngine: ReventlessSpec.QueryEngine.t,
      ~publishCommands: publishCommands,
      ~queueMessage: queueEvent,
      ~createSchedule: ReventlessSpec.Schedule.create,
      ~deleteSchedule: ReventlessSpec.Schedule.delete,
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
          switch (
            sideEffects->findSideEffect(event'Json->Js.Json.decodeObject)
          ) {
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
          }
        )
      ->Js.Promise.all
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _);
    };

  let construct =
      (
        ~sideEffects,
        ~queryEngine,
        ~scheduler: Scheduler.t,
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

    let publishCommands =
      (. queueName, entries) => {
        let count = entries->Belt.Array.size;
        entries
        ->Belt.Array.mapWithIndex(
            (idx, (id, meta: Message.meta, messageBody)) => {
            let idx = idx + 1;
            Js.log({j|Task.publishCommands $idx/$count: $messageBody|j});
            AwsSdk.SQS.makeBatchEntry(
              // TODO: move to Adapter
              ~groupId=id,
              ~messageBody,
              ~messageId=meta.msgId,
              ~delay=None,
            );
          })
        ->AwsSdk.SQS.sendMessageBatch(
            // TODO: move to Adapter
            ~queueId=
              resources->Util.Aggregate.commandTopicConnectorResource(
                queueName,
              )##id
              ->OutputFailsafeRuntime.get,
          )
        |> Js.Promise.catch(err =>
             Js.Promise.resolve(Js.log2("Task.publishCommands Error:", err))
           );
      };

    let queueMessage =
      (. delay, _id, messageBody) => {
        let queueId =
          resources->Util.EventCollector.getConnectorResource(name)##id
          ->OutputFailsafeRuntime.get;
        Js.log4("Task.queueMessage:", delay, messageBody, queueId);
        AwsSdk.SQS.sendMessage(
          // TODO: move to Adapter
          ~queueId,
          // ~messageGroupId=id,
          ~messageBody,
          ~delay,
          (),
        );
      };

    let createSchedule =
      (. schedule: ReventlessSpec.Schedule.schedule) =>
        (
          Schedule.create(
            scheduler,
            resources->Util.EventCollector.getConnectorResource(name),
          )
        )(.
          schedule,
        );

    let deleteSchedule =
      (. scheduleName) =>
        (
          Schedule.delete(
            scheduler,
            resources->Util.EventCollector.getConnectorResource(name),
          )
        )(.
          scheduleName,
        );

    let eventsHandler = eventsHandler(sideEffects, queryEngine);
    let eventCollector =
      EventCollector.make(
        ~name,
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
      ~queryEngine,
      ~publishCommands,
      ~queueMessage,
      ~createSchedule,
      ~deleteSchedule,
    )
    ->setOutputs(self, _);
  };

  let make =
      (
        ~name,
        ~sideEffects,
        ~queryEngine,
        ~scheduler,
        ~memorySize=2048,
        ~timeout=180,
        ~opts,
        ~resources,
        _,
      ) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=
        construct(
          ~sideEffects,
          ~queryEngine,
          ~scheduler,
          ~memorySize,
          ~timeout,
        ),
      ~opts,
      ~resources,
    );
  };
};
