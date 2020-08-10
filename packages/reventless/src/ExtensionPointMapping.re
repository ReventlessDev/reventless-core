type extensionPointName = string;

type commandAction('command, 'msg) =
  | PublishCommand(string, 'command)
  | Call(Message.handler('msg), 'msg);
type commandActions('command, 'msg) = array(commandAction('command, 'msg));

type eventAction('event, 'msg) =
  | PublishEvent('event)
  | Call(Message.handler('msg), 'msg);
type eventActions('event, 'msg) = array(eventAction('event, 'msg));

// type mapCommandJson = Js.Json.t => commandActions(Js.Json.t);
// type mapEventJson = Js.Json.t => eventActions(Js.Json.t);

module type Impl = {
  module ExtensionPoint: ExtensionPointDefinition.T;
  module Aggregate: Message.Service;

  let mapIncomingCommand:
    (ExtensionPointDefinition.id, ExtensionPoint.command, Message.meta) =>
    commandActions((Aggregate.id, Aggregate.command), 'msg);
  let mapOutgoingEvent:
    (Aggregate.id, Aggregate.event, Message.meta) =>
    eventActions((ExtensionPointDefinition.id, ExtensionPoint.event), 'msg);
};

module type T = {
  module ExtensionPoint: ExtensionPointDefinition.T;
  module Aggregate: Message.Service;

  let mapIncomingCommands:
    array(
      Message.command'(ExtensionPointDefinition.id, ExtensionPoint.command),
    ) =>
    commandActions(Js.Json.t, 'msg);
  let mapOutgoingEvent:
    Js.Json.t =>
    eventActions(
      Message.event'(ExtensionPointDefinition.id, ExtensionPoint.event),
      'msg,
    );
};

module Make =
       (
         ExtensionPoint: ExtensionPointDefinition.T,
         Aggregate: Message.Service,
         MappingImpl:
           Impl with
             module ExtensionPoint = ExtensionPoint and
             module Aggregate = Aggregate,
       )
       : T => {
  module ExtensionPoint = ExtensionPoint;
  module Aggregate = Aggregate;

  let mapIncomingCommands = commands' =>
    commands'
    ->Belt.Array.map(({Message.id, command, meta}) =>
        MappingImpl.mapIncomingCommand(id, command, meta)
        ->Belt.Array.map(
            fun
            | PublishCommand(aggregateName, (aggregateId, aggregateCmd)) =>
              PublishCommand(
                aggregateName,
                Message.command'_encode(
                  Aggregate.id_encode,
                  Aggregate.command_encode,
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

  let mapOutgoingEvent = aggregateEvent'Json =>
    switch (
      Message.event'_decode(
        Aggregate.id_decode,
        Aggregate.event_decode,
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
