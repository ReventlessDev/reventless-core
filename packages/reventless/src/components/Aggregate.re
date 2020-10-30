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
  };

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
          |> Js.Promise.then_(value => Js.Promise.resolve(Some(value)))
        | None => Js.Promise.resolve(None);

      eventLogReplay(. id)
      |> Js.Promise.then_(history => {
           let processCommand =
               (promise, command': Message.command'(Spec.Id.t, Spec.command)) => {
             let countPromise =
               Behaviour.atomicCounter->Belt.Option.flatMap(
                 ({name, shouldIncrement}) =>
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
               |> sequencePromiseOption;
             Js.Promise.all2((promise, countPromise))
             |> Js.Promise.then_((((stateOpt, events), count)) => {
                  switch (count) {
                  | Some(count) =>
                    Js.log(
                      {j|Aggregate.processCommand: AtomicCounter for $name($id) count: $count|j},
                    )
                  | None => ()
                  };
                  switch (stateOpt) {
                  | Some(state) =>
                    let newEvents =
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
                    Js.Promise.resolve((
                      updateState(stateOpt, newEvents),
                      events @ [(newEvents, command' |> updateMeta)],
                    ));
                  | None =>
                    let newEvents =
                      Behaviour.create(.
                        command'.command,
                        {
                          id: command'.id |> Spec.Id.toString,
                          meta: command'.meta,
                        },
                        errorHandler,
                        count,
                      );
                    Js.Promise.resolve((
                      updateState(None, newEvents),
                      events @ [(newEvents, command' |> updateMeta)],
                    ));
                  };
                });
           };

           commands'->Belt.Array.reduce(
             (updateState(None, history->Belt.List.fromArray), [])
             ->Js.Promise.resolve,
             processCommand,
           )
           |> Js.Promise.then_(((_, newEvents)) => {
                let newEvents' =
                  newEvents
                  ->Belt.List.map(((events, meta)) =>
                      events->Belt.List.map(event =>
                        {Message.id, meta, event}
                      )
                    )
                  ->Belt.List.flatten
                  ->Belt.List.toArray;

                Js.Promise.all2((
                  eventLogAppend(. history->Belt.Array.length, id, newEvents')
                  |> Js.Promise.catch(err =>
                       Js.Promise.reject(
                         failwith(
                           {j|Aggregate.execCommand($id): eventLogAppend error: |j}
                           ++ err
                              ->Js.Json.stringifyAny
                              ->Belt.Option.getWithDefault("unknown error"),
                         ),
                       )
                     ),
                  eventsHandler(. id, newEvents')
                  |> Js.Promise.catch(err =>
                       Js.Promise.reject(
                         failwith(
                           {j|Aggregate.execCommand($id): eventsHandler error: |j}
                           ++ err
                              ->Js.Json.stringifyAny
                              ->Belt.Option.getWithDefault("unknown error"),
                         ),
                       )
                     ),
                ))
                |> Js.Promise.then_(_ =>
                     eventTopicPublish(. newEvents')
                     |> Js.Promise.catch(err =>
                          Js.Promise.reject(
                            failwith(
                              {j|Aggregate.execCommand($id): eventTopicPublish error: |j}
                              ++ err
                                 ->Js.Json.stringifyAny
                                 ->Belt.Option.getWithDefault("unknown error"),
                            ),
                          )
                        )
                   );
              });
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
