type extensionPointName = string;

type commandAction('command, 'msg) =
  | PublishCommand(string, 'command)
  | Call(Message.handler('msg), 'msg);
type commandActions('command, 'msg) = array(commandAction('command, 'msg));

type eventAction('event, 'msg) =
  | PublishEvent('event)
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

type mapIncomingCommand('extensionPointCommand, 'aggregateId, 'aggregateCommand, 'extensionPointCallCommand) = (Id.String.t, 'extensionPointCommand, Message.meta) =>
    commandActions(
      ('aggregateId, 'aggregateCommand),
      'extensionPointCallCommand,
    );

module type Impl = {
  module ExtensionPoint: Spec;
  module Aggregate: Aggregate.Spec;

  let mapIncomingCommand:
    (Id.String.t, ExtensionPoint.command, Message.meta) =>
    commandActions(
      (Aggregate.Id.t, Aggregate.command),
      ExtensionPoint.callCommand,
    );
  let mapOutgoingEvent:
    (Aggregate.Id.t, Aggregate.event, Message.meta) =>
    eventActions(
      (Id.String.t, ExtensionPoint.event),
      ExtensionPoint.callCommand,
    );
};

module type T = {
  module ExtensionPoint: Spec;

  let aggregateName: string;

  let mapIncomingCommands:
    array(Message.command'(Id.String.t, ExtensionPoint.command)) =>
    commandActions(Js.Json.t, ExtensionPoint.callCommand);

  let mapOutgoingEvent:
    Js.Json.t =>
    eventActions(
      Message.event'(Id.String.t, ExtensionPoint.event),
      ExtensionPoint.callCommand,
    );
};

module Make =
       (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec)
       : (T with module ExtensionPoint := Spec) => {
  let aggregateName = MappingImpl.Aggregate.name;

  let mapIncomingCommands:
    array(Message.command'(Id.String.t, Spec.command)) =>
    commandActions(Js.Json.t, Spec.callCommand) =
    commands' =>
      commands'
      ->Belt.Array.map(({Message.id, command, meta}) =>
          MappingImpl.mapIncomingCommand(id, command, meta)
          ->Belt.Array.map(
              fun
              | PublishCommand(aggregateName, (aggregateId, aggregateCmd)) =>
                PublishCommand(
                  aggregateName,
                  Message.command'_encode(
                    MappingImpl.Aggregate.Id.t_encode,
                    MappingImpl.Aggregate.command_encode,
                    {
                      id: aggregateId,
                      meta: {
                        ...meta,
                        msgId: Message.uuid(),
                      },
                      command: aggregateCmd,
                    },
                  ),
                )
              | Call(handler, msg) => Call(handler, msg),
            )
        )
      ->Belt.Array.concatMany;

  let mapOutgoingEvent:
    Js.Json.t =>
    eventActions(
      Message.event'(Id.String.t, Spec.event),
      Spec.callCommand,
    ) =
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
            | PublishEvent((id, event)) =>
              PublishEvent({Message.id, event, meta})
            | Call(handler, msg) => Call(handler, msg),
          )
      | Error(_) =>
        Js.Exn.raiseError(
          "ExtensionPointMapping.Make.mapOutgoing: Decode failure: " // TODO improve message
        )
      };
};
