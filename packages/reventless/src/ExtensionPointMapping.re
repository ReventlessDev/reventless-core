type extensionPointName = string;

type callHandler('msg) =
  (Schedule.create, Schedule.delete, 'msg) => Js.Promise.t(unit);

/* these actions are needed for Impl */
type commandAction('command, 'msg) =
  | PublishCommand(string, 'command)
  | Call(callHandler('msg), 'msg);

type eventAction('event, 'msg) =
  | PublishEvent(string, 'event)
  | Call(callHandler('msg), 'msg);

module type Spec = {
  let name: string;

  [@decco]
  type command;
  [@decco]
  type event;
  [@decco]
  type callCommand;

  let initEvent: event;
};

type mapIncomingCommand(
  'extensionPointCommand,
  'aggregateId,
  'aggregateCommand,
  'extensionPointCallCommand,
) =
  (string, 'extensionPointCommand, Message.meta) =>
  array(commandAction('aggregateCommand, 'extensionPointCallCommand));

type mapOutgoingEvent(
  'aggregateId,
  'aggregateEvent,
  'extensionPointEvent,
  'extensionPointCallCommand,
) =
  (string, 'aggregateEvent, Message.meta) =>
  array(eventAction('extensionPointEvent, 'extensionPointCallCommand));

module type Impl = {
  module ExtensionPoint: Spec;
  module Aggregate: Aggregate.Spec;

  let mapIncomingCommand:
    mapIncomingCommand(
      ExtensionPoint.command,
      Aggregate.Id.t,
      Aggregate.command,
      ExtensionPoint.callCommand,
    );

  let mapOutgoingEvent:
    mapOutgoingEvent(
      Aggregate.Id.t,
      Aggregate.event,
      ExtensionPoint.event,
      ExtensionPoint.callCommand,
    );
};

/* these actions are internal to the Mapping Functor */
type abstractCommandAction =
  | AbstractPublishCommand(Aggregate.name, Js.Json.t)
  | AbstractCall(unit => Js.Promise.t(unit));

type abstractEventAction('extensionPointEvent) =
  | AbstractPublishEvent(Message.event'(Id.String.t, 'extensionPointEvent))
  | AbstractCall(unit => Js.Promise.t(unit));

module type T = {
  module ExtensionPoint: Spec;

  let aggregateName: string;

  let mapIncomingCommands:
    (
      array(Message.command'(Id.String.t, ExtensionPoint.command)),
      Schedule.create,
      Schedule.delete
    ) =>
    array(abstractCommandAction);

  let mapOutgoingEvent:
    (Js.Json.t, Schedule.create, Schedule.delete) =>
    array(abstractEventAction(ExtensionPoint.event));
};

module Make =
       (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec)
       : (T with module ExtensionPoint := Spec) => {
  module Aggregate = MappingImpl.Aggregate;
  let aggregateName = Aggregate.name;
  let extensionPointName = Spec.name;

  let mapIncomingCommands = (commands', createSchedule, deleteSchedule) =>
    commands'
    ->Belt.Array.map(({Message.id, command, meta}) =>
        MappingImpl.mapIncomingCommand(id->Id.String.toString, command, meta)
        ->Belt.Array.map(
            fun
            | PublishCommand(aggregateId, aggregateCmd) => {
                let commandStr =
                  aggregateCmd->Aggregate.command_encode->Js.Json.stringify;
                Js.log(
                  {j|ExtensionPointMapping incoming from ExtensionPoint $extensionPointName to Aggregate $aggregateName: Publishing command: $commandStr id: $id|j},
                );

                AbstractPublishCommand(
                  aggregateName,
                  Message.command'_encode(
                    Aggregate.Id.t_encode,
                    Aggregate.command_encode,
                    {
                      id: aggregateId->Aggregate.Id.makeFromString,
                      meta: {
                        ...meta,
                        service: Aggregate.name,
                        msgId: Message.uuid(),
                      },
                      command: aggregateCmd,
                    },
                  ),
                );
              }
            | Call(handler, callCommand) => {
                Js.log2(
                  {j|ExtensionPointMapping incoming from ExtensionPoint $extensionPointName: Handling call command|j},
                  callCommand->Spec.callCommand_encode->Js.Json.stringify,
                );

                AbstractCall(
                  () => handler(createSchedule, deleteSchedule, callCommand),
                );
              },
          )
      )
    ->Belt.Array.concatMany;

  let mapOutgoingEvent = (aggregateEvent'Json, createSchedule, deleteSchedule) =>
    switch (
      Message.event'_decode(
        Aggregate.Id.t_decode,
        Aggregate.event_decode,
        aggregateEvent'Json,
      )
    ) {
    | Ok({id, meta, event}) =>
      MappingImpl.mapOutgoingEvent(id->Aggregate.Id.toString, event, meta)
      ->Belt.Array.map(
          fun
          | PublishEvent(id, event) => {
              let eventStr = event->Spec.event_encode->Js.Json.stringify;
              Js.log(
                {j|ExtensionPointMapping outgoing from Aggregate $aggregateName to ExtensionPoint $extensionPointName: Publishing event: $eventStr id: $id|j},
              );

              AbstractPublishEvent({
                Message.id: id->Id.String.makeFromString,
                event,
                meta: {
                  ...meta,
                  service: Spec.name,
                  msgId: Message.uuid(),
                },
              });
            }
          | Call(handler, msg) => {
              Js.log2(
                {j|ExtensionPointMapping outgoing from Aggregate $aggregateName: Handling call command|j},
                msg->Spec.callCommand_encode->Js.Json.stringify,
              );

              AbstractCall(
                () => handler(createSchedule, deleteSchedule, msg),
              );
            },
        )
    | Error(_) =>
      Js.Exn.raiseError(
        "ExtensionPointMapping.Make.mapOutgoing: Decode failure: " // TODO improve message
      )
    };
};
