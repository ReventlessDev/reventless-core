type extensionPointName = string;

/* these actions are needed for Impl */
type commandAction('command, 'msg) =
  | PublishCommand(string, 'command)
  | Call(Message.handler('msg), 'msg);
type commandActions('command, 'msg) = array(commandAction('command, 'msg));

type eventAction('event, 'msg) =
  | PublishEvent(string, 'event)
  | Call(Message.handler('msg), 'msg);
type eventActions('event, 'msg) = array(eventAction('event, 'msg));

module type Spec = {
  let name: string;

  [@decco]
  type command;
  [@decco]
  type event;
  [@decco]
  type callCommand;
};

type mapIncomingCommand(
  'extensionPointCommand,
  'aggregateId,
  'aggregateCommand,
  'extensionPointCallCommand,
) =
  (Id.String.t, 'extensionPointCommand, Message.meta) =>
  commandActions('aggregateCommand, 'extensionPointCallCommand);

type mapOutgoingEvent(
  'aggregateId,
  'aggregateEvent,
  'extensionPointEvent,
  'extensionPointCallCommand,
) =
  ('aggregateId, 'aggregateEvent, Message.meta) =>
  eventActions('extensionPointEvent, 'extensionPointCallCommand);

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
  | AbstractCall(Message.handler(unit));
type abstractCommandActions = array(abstractCommandAction);

type abstractEventAction('extensionPointEvent) =
  | AbstractPublishEvent(Message.event'(Id.String.t, 'extensionPointEvent))
  | AbstractCall(Message.handler(unit));
type abstractEventActions('extensionPointEvent) =
  array(abstractEventAction('extensionPointEvent));

module type T = {
  module ExtensionPoint: Spec;

  let aggregateName: string;

  let mapIncomingCommands:
    array(Message.command'(Id.String.t, ExtensionPoint.command)) =>
    abstractCommandActions;

  let mapOutgoingEvent:
    Js.Json.t => abstractEventActions(ExtensionPoint.event);
};

module Make =
       (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec)
       : (T with module ExtensionPoint := Spec) => {
  let aggregateName = MappingImpl.Aggregate.name;

  let mapIncomingCommands:
    array(Message.command'(Id.String.t, Spec.command)) =>
    abstractCommandActions =
    commands' =>
      commands'
      ->Belt.Array.map(({Message.id, command, meta}) =>
          MappingImpl.mapIncomingCommand(id, command, meta)
          ->Belt.Array.map(
              fun
              | PublishCommand(aggregateId, aggregateCmd) =>
                AbstractPublishCommand(
                  aggregateName,
                  Message.command'_encode(
                    MappingImpl.Aggregate.Id.t_encode,
                    MappingImpl.Aggregate.command_encode,
                    {
                      id: aggregateId->MappingImpl.Aggregate.Id.makeFromString,
                      meta: {
                        ...meta,
                        msgId: Message.uuid(),
                      },
                      command: aggregateCmd,
                    },
                  ),
                )
              | Call(handler, msg) => AbstractCall(() => handler(msg)),
            )
        )
      ->Belt.Array.concatMany;

  let mapOutgoingEvent: Js.Json.t => abstractEventActions(Spec.event) =
    aggregateEvent'Json =>
      switch (
        Message.event'_decode(
          MappingImpl.Aggregate.Id.t_decode,
          MappingImpl.Aggregate.event_decode,
          aggregateEvent'Json,
        )
      ) {
      | Ok({id, meta, event}) =>
        MappingImpl.mapOutgoingEvent(id, event, meta)
        ->Belt.Array.map(
            fun
            | PublishEvent(id, event) =>
              AbstractPublishEvent({
                Message.id: id->Id.String.makeFromString,
                event,
                meta,
              })
            | Call(handler, msg) => AbstractCall(() => handler(msg)),
          )
      | Error(_) =>
        Js.Exn.raiseError(
          "ExtensionPointMapping.Make.mapOutgoing: Decode failure: " // TODO improve message
        )
      };
};
