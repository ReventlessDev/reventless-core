type extensionPointName = string;

/* these actions are needed for Impl */
type incomingCommandAction('aggregateCommand, 'extensionPointCommand, 'msg) =
  | PublishAggregateCommand(string, 'aggregateCommand)
  | PublishExtensionPointCommand(string, 'extensionPointCommand)
  | Call(Message.handler('msg), 'msg);
type incomingCommandActions('aggregateCommand, 'extensionPointCommand, 'msg) =
  array(
    incomingCommandAction('aggregateCommand, 'extensionPointCommand, 'msg),
  );

type outgoingCommandAction('extensionPointCommand, 'msg) =
  | PublishExtensionPointCommand(string, 'extensionPointCommand)
  | Call(Message.handler('msg), 'msg);
type outgoingCommandActions('extensionPointCommand, 'msg) =
  array(outgoingCommandAction('extensionPointCommand, 'msg));

module type Spec = {
  let name: string;

  [@decco]
  type command;
  [@decco]
  type event;
  [@decco]
  type callCommand;
};

type mapIncomingEvent(
  'extensionPointEvent,
  'aggregateId,
  'aggregateCommand,
  'extensionPointCommand,
  'extensionPointCallCommand,
) =
  (string, 'extensionPointEvent, Message.meta) =>
  incomingCommandActions(
    'aggregateCommand,
    'extensionPointCommand,
    'extensionPointCallCommand,
  );

type mapOutgoingEvent(
  'aggregateId,
  'aggregateEvent,
  'extensionPointCommand,
  'extensionPointCallCommand,
) =
  (string, 'aggregateEvent, Message.meta) =>
  outgoingCommandActions('extensionPointCommand, 'extensionPointCallCommand);

/* these actions are internal to the Mapping Functor */
type abstractIncomingCommandAction =
  | AbstractPublishAggregateCommand(Aggregate.name, Js.Json.t)
  | AbstractPublishExtensionPointCommand(Js.Json.t)
  | AbstractCall(Message.handler(unit));
type abstractIncomingCommandActions = array(abstractIncomingCommandAction);

type abstractOutgoingCommandAction =
  | AbstractPublishExtensionPointCommand(Js.Json.t)
  | AbstractCall(Message.handler(unit));
type abstractOutgoingCommandActions = array(abstractOutgoingCommandAction);

module type Impl = {
  module ExtensionPoint: Spec;
  module Aggregate: Aggregate.Spec;

  let mapIncomingEvent:
    mapIncomingEvent(
      ExtensionPoint.event,
      Aggregate.Id.t,
      Aggregate.command,
      ExtensionPoint.command,
      ExtensionPoint.callCommand,
    );

  let mapOutgoingEvent:
    mapOutgoingEvent(
      Aggregate.Id.t,
      Aggregate.event,
      ExtensionPoint.command,
      ExtensionPoint.callCommand,
    );
};

module type T = {
  module ExtensionPoint: Spec;

  let aggregateName: string;

  let mapIncomingEvent:
    Message.event'(Id.String.t, ExtensionPoint.event) =>
    abstractIncomingCommandActions;

  let mapOutgoingEvent: Js.Json.t => abstractOutgoingCommandActions;
};

module Make =
       (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec)
       : (T with module ExtensionPoint := Spec) => {
  module Aggregate = MappingImpl.Aggregate;
  let aggregateName = Aggregate.name;
  let extensionPointName = Spec.name;

  let mapIncomingEvent:
    Message.event'(Id.String.t, Spec.event) => abstractIncomingCommandActions =
    ({Message.id, event, meta}) =>
      MappingImpl.mapIncomingEvent(id->Id.String.toString, event, meta)
      ->Belt.Array.map(
          fun
          | PublishAggregateCommand(aggregateId, aggregateCmd) => {
              Js.log2(
                {j|ExtensionMapping incoming from ExtensionPoint $extensionPointName to Aggregate $aggregateName: Publishing Aggregate command|j},
                aggregateCmd->Aggregate.command_encode->Js.Json.stringify,
              );

              AbstractPublishAggregateCommand(
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
          | PublishExtensionPointCommand(id, command) => {
              Js.log2(
                {j|ExtensionMapping incoming from ExtensionPoint $extensionPointName to Aggregate $aggregateName: Publishing ExtensionPoint command|j},
                command->Spec.command_encode->Js.Json.stringify,
              );

              AbstractPublishExtensionPointCommand(
                Message.command'_encode(
                  Id.String.t_encode,
                  Spec.command_encode,
                  {
                    id: id->Id.String.makeFromString,
                    meta: {
                      ...meta,
                      msgId: Message.uuid(),
                    },
                    command,
                  },
                ),
              );
            }
          | Call(handler, callCommand) => {
              Js.log2(
                {j|ExtensionMapping incoming from ExtensionPoint $extensionPointName to Aggregate $aggregateName: Handling call command|j},
                callCommand->Spec.callCommand_encode->Js.Json.stringify,
              );

              AbstractCall(() => handler(callCommand));
            },
        );

  let mapOutgoingEvent: Js.Json.t => abstractOutgoingCommandActions =
    aggregateEvent'Json =>
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
            | PublishExtensionPointCommand(id, command) => {
                Js.log2(
                  {j|ExtensionMapping outgoing from Aggregate $aggregateName to ExtensionPoint $extensionPointName: Publishing ExtensionPoint command|j},
                  command->Spec.command_encode->Js.Json.stringify,
                );

                AbstractPublishExtensionPointCommand(
                  Message.command'_encode(
                    Id.String.t_encode,
                    Spec.command_encode,
                    {
                      id: id->Id.String.makeFromString,
                      meta: {
                        ...meta,
                        service: Spec.name,
                        msgId: Message.uuid(),
                      },
                      command,
                    },
                  ),
                );
              }
            | Call(handler, callCommand) => {
                Js.log2(
                  {j|ExtensionMapping outgoing from Aggregate $aggregateName to ExtensionPoint $extensionPointName: Handling call command|j},
                  callCommand->Spec.callCommand_encode->Js.Json.stringify,
                );

                AbstractCall(() => handler(callCommand));
              },
          )
      | Error(_) =>
        Js.Exn.raiseError(
          "ExtensionPointMapping.Make.mapOutgoing: Decode failure: " // TODO improve message
        )
      };
};

module NoAggregate: Aggregate.Spec = {
  let name = "NoAggregate";

  module Id = Id.String;

  [@decco]
  type command = unit;

  [@decco]
  type event = unit;

  [@decco]
  type error = unit;
};
