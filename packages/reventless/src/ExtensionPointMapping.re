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
  module Id: Id.T;

  let name: string;

  [@decco]
  type command;
  [@decco]
  type event;
};

module type Impl = {
  module ExtensionPoint: Spec;
  module Aggregate: Aggregate.Spec;

  type callCommand;

  let mapIncomingCommand:
    (ExtensionPoint.Id.t, ExtensionPoint.command, Message.meta) =>
    commandActions((Aggregate.Id.t, Aggregate.command), callCommand);
  let mapOutgoingEvent:
    (Aggregate.Id.t, Aggregate.event, Message.meta) =>
    eventActions((ExtensionPoint.Id.t, ExtensionPoint.event), callCommand);
};

module type T = {
  module ExtensionPoint: Spec;
  module Aggregate: Aggregate.Spec;

  type callCommand;

  let mapIncomingCommands:
    array(Message.command'(ExtensionPoint.Id.t, ExtensionPoint.command)) =>
    commandActions(Js.Json.t, callCommand);

  let mapOutgoingEvent:
    Js.Json.t =>
    eventActions(
      Message.event'(ExtensionPoint.Id.t, ExtensionPoint.event),
      callCommand,
    );
};

module Make =
       (MappingImpl: Impl)

         : (
           T with
             module ExtensionPoint := MappingImpl.ExtensionPoint and
             module Aggregate = MappingImpl.Aggregate
       ) => {
  module Aggregate = MappingImpl.Aggregate;
  type callCommand = MappingImpl.callCommand;

  let mapIncomingCommands:
    array(
      Message.command'(
        MappingImpl.ExtensionPoint.Id.t,
        MappingImpl.ExtensionPoint.command,
      ),
    ) =>
    commandActions(Js.Json.t, callCommand) =
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
      Message.event'(
        MappingImpl.ExtensionPoint.Id.t,
        MappingImpl.ExtensionPoint.event,
      ),
      callCommand,
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
