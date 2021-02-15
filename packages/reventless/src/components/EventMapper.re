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

module type T = {let make: maker;};

module Make =
       (
         EventMappings: EventMapping.Mappings,
         EventCollector: EventCollector.T,
       )
       : T => {
  type constructed;
  type construct = (Component.t(eventMapper, outputs), string) => constructed;

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

  let findMapping = eventObj =>
    eventObj->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode)
    |> (
      fun
      | Some(Belt.Result.Ok(eventMeta)) =>
        EventMappings.mappings->Js.Dict.get(eventMeta.service)
        |> (
          fun
          | None => {
              Js.log2(
                "EventMapper.map: No mapping available for service:",
                eventMeta.service,
              );
              None;
            }
          | Some(mapping) => Some((eventObj, eventMeta, mapping))
        )
      | Some(Error(err)) => {
          Js.log2("EventMapper.map: Couldn't decode meta:", err);
          None;
        }
      | _ => {
          Js.log("EventMapper.map: Invalid JSON object");
          None;
        }
    );

  let map = (queryCommandTopic, queryEngine) =>
    (. event'Json) => {
      event'Json->Message.logEvent'Json("EventMapper.map: incoming event:");
      event'Json->Js.Json.decodeObject->Belt.Option.flatMap(findMapping)
      |> (
        fun
        | Some((eventObj, eventMeta, mapping)) => {
            let publish =
                (
                  idx,
                  (service, (commandId, command), idEncoder, commandEncoder),
                ) => {
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
              let commandStr = command->commandEncoder->Js.Json.stringify;
              let source = eventMeta.service;
              Js.log(
                {j|EventMapping from Aggregate $source to Aggregate $service: Publishing command: $commandStr id: $commandId|j},
              );

              {Message.id: commandId, meta: commandMeta, command}
              |> Message.command'_encode(idEncoder, commandEncoder)
              |> Js.Json.stringify
              |> AwsSdk.SQS.sendMessage(~queueId, ~messageBody=_, ())
              |> Js.Promise.catch(err =>
                   err
                   |> Js.log2("EventMapper: Error on publish command:")
                   |> Js.Promise.resolve
                 );
            };

            module Mapping = (val mapping);
            (
              eventObj
              ->Js.Dict.get("id")
              ->Belt.Option.map(Mapping.eventIdDecoder),
              eventObj
              ->Js.Dict.get("event")
              ->Belt.Option.map(Mapping.eventDecoder),
            )
            |> (
              fun
              | (Some(Ok(eventId)), Some(Ok(event))) =>
                Mapping.map(. eventId, event, queryEngine)
                ->Belt.Array.mapWithIndex((idx, action) =>
                    switch (action) {
                    | EventMapping.PublishToQueue(
                        service,
                        (commandId, command),
                        idEncoder,
                        commandEncoder,
                      ) =>
                      publish(
                        idx,
                        (
                          service,
                          (commandId, command),
                          idEncoder,
                          commandEncoder,
                        ),
                      )
                    | EventMapping.PublishToQueueAsync(promise) =>
                      promise->Js.Promise.then_(
                                 data => publish(idx, data),
                                 _,
                               )
                    | Call(commandHandler, command) =>
                      command
                      |> commandHandler
                      |> Js.Promise.catch(err =>
                           err
                           |> Js.log2(
                                "EventMapper: Error in commandHandler:",
                              )
                           |> Js.Promise.resolve
                         )
                    | Nothing => Js.Promise.resolve()
                    }
                  )
                |> Js.Promise.all
                |> Js.Promise.then_(_ => Js.Promise.resolve())
              | (None, _)
              | (_, None) =>
                Js.Promise.resolve(Js.log("EventMapper.map: Invalid event"))
              | (_, Some(Error(err)))
              | (Some(Error(err)), _) =>
                Js.Promise.resolve(
                  Js.log2("EventMapper.map: Couldn't decode event:", err),
                )
            );
          }
        | None => Js.Promise.resolve()
      );
    };

  let construct =
      (
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
        ~name=EventMappings.name,
        ~aggregateNames=
          EventMappings.mappings
          ->Js.Dict.entries
          ->Belt.Array.map(((eventService, _)) => eventService),
        ~eventHandler=map(queryCommandTopic, queryEngine),
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
      ~queryEngine,
      ~queryCommandTopic,
      ~queryEventTopic,
      ~memorySize,
      ~timeout: int=180,
      ~opts,
      _unit,
    ) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=EventMappings.name,
        ~construct=
          construct(
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
