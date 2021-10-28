open ReventlessSpec.Adapter;
open Belt.Result;

let componentType = ComponentType.Aggregate;

type outputs = {
  .
  "commandGenerator": CommandGenerator.outputs,
  "commandTopic": CommandTopic.outputs,
  "eventLog": EventLog.outputs,
  "eventTopic": EventTopic.outputs,
};

type name = string;

module type T = {
  module Spec: ReventlessSpec.AggregateSpec.T;
  type t;

  let make:
    (
      ~eventsHandler: Message.eventsHandler(Spec.Id.t, Spec.event),
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);
};

module Make =
       (
         Config: Config.T,
         Spec: ReventlessSpec.AggregateSpec.T,
         Behaviour: Behaviour.T with module Spec := Spec,
         CommandGeneratorResolvers:
           CommandGenerator.Adapter.Resolvers with type api := Config.api,
         CommandTopicConnector: CommandTopic.Adapter.Connector,
         EventLogStorage: EventLog.Adapter.Storage,
         EventTopicPublisher: EventTopic.Adapter.Publisher,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;
  type t;

  type eventsHandler = Message.eventsHandler(Spec.Id.t, Spec.event);

  type constructed;
  type construct =
    (Component.t(t, outputs), string, eventsHandler, resources) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~eventsHandler: eventsHandler,
      ~resources: resources
    ) =>
    Component.t(t, outputs) =
    "default";

  module CommandGenerator =
    CommandGenerator.Make(Config, Spec, Behaviour, CommandGeneratorResolvers);
  module CommandTopic = CommandTopic.Make(Spec, CommandTopicConnector);
  module EventLog = EventLog.Make(Spec, EventLogStorage);
  module EventTopic = EventTopic.Make(Spec, EventTopicPublisher);

  [@bs.obj]
  external makeOutputs:
    (
      ~commandGenerator: Reventless.CommandGenerator.outputs,
      ~commandTopic: Reventless.CommandTopic.outputs,
      ~eventLog: Reventless.EventLog.outputs,
      ~eventTopic: Reventless.EventTopic.outputs
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

  let errorHandler = (error, command, context: Message.context) => {
    let errorJson = error |> Spec.error_encode |> Js.Json.stringify;
    let commandJson = command |> Spec.command_encode |> Js.Json.stringify;
    let serviceName = Spec.name;
    let id = context.id;
    Js.log(
      {j|Behaviour error $errorJson in $serviceName($id): Command: $commandJson|j},
    );
    [];
  };

  let eventName: Message.event'(Spec.Id.t, Spec.event) => string =
    event' => event'.event->Spec.event_encode->Obj.magic[0];

  let errorMessage = (id, kind, err) =>
    {j|Aggregate.execCommand($id): $kind Error: |j}
    ++
    err->AwsSdk.Error.ofPromise##message;

  let logCommand' =
      (
        idx,
        count,
        reference,
        command': Message.command'(Spec.Id.t, Spec.command),
      ) => {
    let id = command'.id;
    let command: array(string) =
      command'.command->Spec.command_encode->Obj.magic;
    let commandName = command[0];
    let commandStr =
      command'
      |> Message.command'_encode(Spec.Id.t_encode, Spec.command_encode)
      |> Js.Json.stringify;
    let idx = idx + 1;
    Js.log(
      {j|CommandTopic: handling command $idx/$count: $commandName($id) ref: $reference, complete command: $commandStr|j},
    );
  };

  let groupTopicItemsById =
      (
        topicItems:
          array(
            Reventless.CommandTopic.topicItem(
              Message.command'(Spec.Id.t, Spec.command),
            ),
          ),
      ) => {
    let ids = topicItems->Belt.Array.map(({command}) => command.id);
    ids
    ->Belt.Set.fromArray(~id=(module Belt.Id.MakeComparable(Spec.Id)))
    ->Belt.Set.toArray
    ->Belt.Array.map(id =>
        (id, topicItems->Belt.Array.keep(({command}) => command.id == id))
      );
  };

  let handleCommands =
      ((eventLogAppend, eventLogReplay, eventTopicPublish, eventsHandler)) =>
    (. allTopicItems) => {
      let apply' = (stateOpt, event) =>
        switch (stateOpt) {
        | Some(state) => Some(Behaviour.apply(. state, event))
        | None => Some(Behaviour.init(. event))
        };

      let updateState = (stateOpt, events) =>
        events->Belt.List.reduce(stateOpt, apply');

      let updateMeta = (command': Message.command'(Spec.Id.t, Spec.command)) => {
        ...command'.meta,
        time: Message.nowAsISOString(),
        msgId: Message.uuid(),
      };

      Js.log("starting Aggregate.execCommands");
      allTopicItems
      ->groupTopicItemsById
      ->Belt.Array.map(((id, topicItems)) =>
          eventLogReplay(. id)
          |> Js.Promise.then_(history => {
               let processCommand =
                   (
                     accP,
                     command': Message.command'(Spec.Id.t, Spec.command),
                   ) => {
                 let runBehaviour = ((stateO, events)) =>
                   switch (stateO) {
                   | Some(state) =>
                     let generatedEvents =
                       try (
                         Behaviour.execute(.
                           state,
                           command'.command,
                           {
                             id: command'.id |> Spec.Id.toString,
                             meta: command'.meta,
                           },
                           errorHandler,
                         )
                       ) {
                       | Message.InvalidEvent(event) =>
                         Js.log2(
                           "Aggregate.processCommand: InvalidEvent",
                           event |> Js.Json.stringify,
                         );
                         [];
                       };
                     Ok((
                       updateState(stateO, generatedEvents),
                       events @ [(generatedEvents, command'->updateMeta)],
                     ))
                     ->Js.Promise.resolve;
                   | None =>
                     let generatedEvents =
                       Behaviour.create(.
                         command'.command,
                         {
                           id: command'.id |> Spec.Id.toString,
                           meta: command'.meta,
                         },
                         errorHandler,
                       );
                     Ok((
                       updateState(None, generatedEvents),
                       events @ [(generatedEvents, command'->updateMeta)],
                     ))
                     ->Js.Promise.resolve;
                   };

                 accP
                 |> Js.Promise.then_(
                      fun
                      | Ok(acc) => runBehaviour(acc)
                      | Error(_) as error => error->Js.Promise.resolve,
                    );
               };

               Js.log({j|finished eventLogReplay for id $id|j});
               let _ =
                 topicItems->Belt.Array.mapWithIndex(
                   (idx, {reference, command}) =>
                   logCommand'(
                     idx,
                     topicItems->Belt.Array.length,
                     reference,
                     command,
                   )
                 );
               let (references, commands') =
                 // TODO: handle finer granular references
                 topicItems
                 ->Belt.Array.map(({reference, command}) =>
                     (reference, command)
                   )
                 ->Belt.Array.unzip;
               commands'->Belt.Array.reduce(
                 Ok((updateState(None, history->Belt.List.fromArray), []))
                 ->Js.Promise.resolve,
                 processCommand,
               )
               |> Js.Promise.then_(
                    fun
                    | Ok((_, generatedEventsWithMeta)) =>
                      generatedEventsWithMeta
                      ->Belt.List.map(((events, meta)) =>
                          events->Belt.List.map(event =>
                            {Message.id, meta, event}
                          )
                        )
                      ->Belt.List.flatten
                      ->Belt.List.toArray
                      ->Js.Promise.resolve
                    | Error(error) => Js.Exn.raiseError(error),
                  )
               |> Js.Promise.then_(
                    fun
                    | [||] =>
                      {
                        Js.log(
                          {j|Aggregate.handleCommands($id): no Event generated|j},
                        );
                        references->Belt.Array.map(reference =>
                          Ok(reference)
                        );
                      }
                      ->Js.Promise.resolve
                    | generatedEvents' => {
                        let eventCount = generatedEvents'->Belt.Array.length;
                        Js.log2(
                          {j|Aggregate.handleCommands($id): $eventCount Event(s) generated:|j},
                          generatedEvents'->Belt.Array.map(event' =>
                            event'->eventName
                          ),
                        );
                        eventsHandler(. id, generatedEvents')
                        |> Js.Promise.catch(err => {
                             let msg = errorMessage(id, "eventsHandler", err);
                             Js.log(msg);
                             Js.Exn.raiseError(msg);
                           })
                        |> Js.Promise.then_(_ => {
                             Js.log({j|finished eventsHandler for id $id|j});
                             eventLogAppend(.
                               history->Belt.Array.length,
                               id,
                               generatedEvents',
                             )
                             |> Js.Promise.then_(result =>
                                  (
                                    switch (result) {
                                    | Ok(_) =>
                                      references->Belt.Array.map(reference =>
                                        Ok(reference)
                                      )
                                    | Error(_) =>
                                      references->Belt.Array.map(reference =>
                                        Error(reference)
                                      )
                                    }
                                  )
                                  ->Js.Promise.resolve
                                );
                           })
                        |> Js.Promise.then_(results => {
                             Js.log({j|finished eventLogAppend for id $id|j});
                             let _ =
                               // FIXME: include in error handling with Belt.Result
                               eventTopicPublish(. generatedEvents')
                               |> Js.Promise.catch(err => {
                                    let msg =
                                      errorMessage(
                                        id,
                                        "eventTopicPublish",
                                        err,
                                      );
                                    Js.log(msg);
                                    Js.Exn.raiseError(msg);
                                  });
                             results->Js.Promise.resolve;
                           });
                      },
                  );
             })
        )
      ->Js.Promise.all
      |> Js.Promise.then_(results =>
           results->Belt.Array.concatMany->Js.Promise.resolve
         );
    };

  let construct: construct =
    (self, name, eventsHandler, resources) => {
      let opts =
        Pulumi.ComponentResource.Options.make(
          ~parent=self->Component.toPulumiResource,
          (),
        );

      let childName = name->ComponentType.name(componentType);

      let eventLog = EventLog.make(~name=childName, ~opts, ~resources, ());
      let eventTopic =
        EventTopic.make(~name=childName, ~opts, ~resources, ());

      let handleCommands =
        handleCommands((
          EventLog.append(eventLog),
          EventLog.replay(eventLog),
          EventTopic.publish(eventTopic),
          eventsHandler,
        ));

      let commandTopic =
        CommandTopic.make(
          ~name=childName,
          ~commandsHandler=handleCommands,
          ~opts,
          ~resources,
          (),
        );

      let commandGenerator =
        CommandGenerator.make(
          ~name=childName,
          ~commandHandler=CommandTopic.publish(commandTopic),
          ~opts,
          ~resources,
          (),
        );

      makeOutputs(
        ~commandGenerator=commandGenerator->Component.extractOutputs,
        ~commandTopic=commandTopic->Component.extractOutputs,
        ~eventLog=eventLog->Component.extractOutputs,
        ~eventTopic=eventTopic->Component.extractOutputs,
      )
      |> self->setOutputs;
    };

  let make:
    (
      ~eventsHandler: eventsHandler,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (~eventsHandler, ~opts=?, ~resources, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct,
        ~opts,
        ~eventsHandler,
        ~resources,
      );
};
