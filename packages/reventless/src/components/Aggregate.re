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

module type Spec = {
  module Id: Id.T;

  let name: string;

  [@decco]
  type command;

  [@decco]
  type event;

  [@decco]
  type error;
};

module type T = {
  module Spec: Spec;
  type t;

  let make:
    (
      ~eventsHandler: Message.eventsHandler(Spec.Id.t, Spec.event),
      ~opts: Pulumi.ComponentResource.Options.t=?,
      unit
    ) =>
    Component.t(t, outputs);
};

module Make =
       (
         Config: Config.T,
         Spec: Spec,
         Behaviour: Behaviour.T with module Spec := Spec,
         CommandGeneratorResolvers:
           CommandGenerator.Resolvers with type api := Config.api,
         CommandTopicConnector: CommandTopic.Connector,
         EventLogStorage: EventLog.Storage,
         EventTopicPublisher: EventTopic.Publisher,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;
  type t;

  type eventsHandler = Message.eventsHandler(Spec.Id.t, Spec.event);

  type constructed;
  type construct =
    (Component.t(t, outputs), string, eventsHandler) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~eventsHandler: eventsHandler
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

  let name = Spec.name;

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

  let stringify = err =>
    err->Js.Json.stringifyAny->Belt.Option.getWithDefault("unknown");

  let execCommands =
      (
        (
          eventLogAppend,
          eventLogReplay,
          eventTopicPublish,
          eventsHandler,
          atomicCounterIncrement,
          atomicCounterGet,
        ),
      ) =>
    (. id, commands': array(Message.command'(Spec.Id.t, Spec.command))) => {
      let apply' = (stateOpt, event) =>
        switch (stateOpt) {
        | Some(state) => Some(Behaviour.apply(. state, event))
        | None => Some(Behaviour.init(. event))
        };

      let updateState = (stateOpt, events) =>
        events->Belt.List.reduce(stateOpt, apply');

      let updateMeta = (command': Message.command'(Spec.Id.t, Spec.command)) => {
        ...command'.meta,
        time: Js.Date.make()->Js.Date.toISOString,
        msgId: Message.uuid(),
      };

      let sequencePromiseOption =
        fun
        | Some(promise) =>
          promise
          |> Js.Promise.then_(value => Some(value)->Js.Promise.resolve)
        | None => None->Js.Promise.resolve;

      eventLogReplay(. id)
      |> Js.Promise.then_(history => {
           let processCommand =
               (accP, command': Message.command'(Spec.Id.t, Spec.command)) => {
             let runBehaviour = (((stateO, events), count)) =>
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
                       count,
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
                   events @ [(generatedEvents, command' |> updateMeta)],
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
                     count,
                   );
                 Ok((
                   updateState(None, generatedEvents),
                   events @ [(generatedEvents, command' |> updateMeta)],
                 ))
                 ->Js.Promise.resolve;
               };

             let count = () =>
               Behaviour.atomicCounter
               ->Belt.Option.flatMap(({name, shouldIncrement}) =>
                   if (shouldIncrement(command'.command)) {
                     Some(
                       atomicCounterIncrement(.
                         name,
                         command'.id |> Spec.Id.toString,
                         command'.meta.correlationId,
                       ),
                     );
                   } else {
                     Some(
                       atomicCounterGet(.
                         name,
                         command'.id |> Spec.Id.toString,
                       ),
                     );
                   }
                 )
               ->sequencePromiseOption;

             accP
             |> Js.Promise.then_(acc =>
                  (
                    switch (acc) {
                    | Ok(_) => (acc->Js.Promise.resolve, count())
                    | Error(_) => (
                        acc->Js.Promise.resolve,
                        None->Js.Promise.resolve,
                      )
                    }
                  )
                  ->Js.Promise.all2
                )
             |> Js.Promise.then_(
                  fun
                  | (Ok(acc), Some(Ok(count))) => {
                      Js.log(
                        {j|Aggregate.processCommand: AtomicCounter for $name($id) count: $count|j},
                      );
                      runBehaviour((acc, Some(count)));
                    }
                  | (Ok(p1), None) => runBehaviour((p1, None))
                  | (Ok(_), Some(Error(err) as error)) => {
                      Js.log(
                        {j|Aggregate.processCommand: counting failed: $err|j},
                      );
                      error->Js.Promise.resolve;
                    }
                  | (Error(_) as error, _) => error->Js.Promise.resolve,
                );
           };

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
                  Js.log({j|Aggregate.execCommand($id): no Event generated|j})
                  ->Js.Promise.resolve
                | generatedEvents' => {
                    let count = generatedEvents'->Belt.Array.length;
                    Js.log(
                      {j|Aggregate.execCommand($id): $count Event generated|j},
                    );
                    eventsHandler(. id, generatedEvents')
                    |> Js.Promise.catch(err => {
                         let error =
                           {j|Aggregate.execCommand($id): eventsHandler Error: |j}
                           ++ err->stringify;
                         Js.log(error);
                         Js.Exn.raiseError(error);
                       })
                    |> Js.Promise.then_(_ =>
                         eventLogAppend(.
                           history->Belt.Array.length,
                           id,
                           generatedEvents',
                         )
                         |> Js.Promise.catch(err => {
                              let error =
                                {j|Aggregate.execCommand($id): eventLogAppend Error: |j}
                                ++ err->stringify;
                              Js.log(error);
                              Js.Exn.raiseError(error);
                            })
                       )
                    |> Js.Promise.then_(_ =>
                         eventTopicPublish(. generatedEvents')
                         |> Js.Promise.catch(err => {
                              let error =
                                {j|Aggregate.execCommand($id): eventTopicPublish Error: |j}
                                ++ err->stringify;
                              Js.log(error);
                              Js.Exn.raiseError(error);
                            })
                       );
                  },
              );
         });
    };

  let construct: construct =
    (self, name, eventsHandler) => {
      let opts =
        Pulumi.ComponentResource.Options.make(
          ~parent=self->Component.toPulumiResource,
          (),
        );

      let childName = name->ComponentType.name(componentType);

      let eventLog = EventLog.make(~name=childName, ~opts, ());
      let eventTopic = EventTopic.make(~name=childName, ~opts, ());

      let execCommands =
        execCommands((
          EventLog.append(eventLog),
          EventLog.replay(eventLog),
          EventTopic.publish(eventTopic),
          eventsHandler,
          Config.atomicCounter##increment,
          Config.atomicCounter##get,
        ));

      let commandTopic =
        CommandTopic.make(
          ~name=childName,
          ~commandsHandler=execCommands,
          ~opts,
          (),
        );

      let commandGenerator =
        CommandGenerator.make(
          ~name=childName,
          ~commandHandler=CommandTopic.publish(commandTopic),
          ~opts,
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
      unit
    ) =>
    Component.t(t, outputs) =
    (~eventsHandler, ~opts=?, _) =>
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=Spec.name,
        ~construct,
        ~opts,
        ~eventsHandler,
      );
};
