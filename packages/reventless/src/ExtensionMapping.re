type extensionPointName = string;

type forwardCommand = {
  extensionPointName: string,
  id: string,
  commandJson: Js.Json.t,
};

/* these actions are needed for Impl */
type incomingCommandAction('aggregateCommand, 'extensionPointCommand, 'msg) =
  | PublishAggregateCommand(string, 'aggregateCommand)
  | PublishExtensionPointCommand(string, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call(Message.handler('msg), 'msg);

type outgoingCommandAction('extensionPointCommand, 'msg) =
  | PublishExtensionPointCommand(string, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call(Message.handler('msg), 'msg);

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
  (string, 'extensionPointEvent, Message.meta, PluginSpec.pluginDefinition) =>
  array(
    incomingCommandAction(
      'aggregateCommand,
      'extensionPointCommand,
      'extensionPointCallCommand,
    ),
  );

type mapOutgoingEvent(
  'aggregateId,
  'aggregateEvent,
  'extensionPointCommand,
  'extensionPointCallCommand,
) =
  (string, 'aggregateEvent, Message.meta, PluginSpec.pluginDefinition) =>
  array(
    outgoingCommandAction('extensionPointCommand, 'extensionPointCallCommand),
  );

/* these actions are internal to the Mapping Functor */
type abstractIncomingCommandAction =
  | AbstractPublishAggregateCommand(Aggregate.name, Js.Json.t)
  | AbstractPublishPluginExtensionPointCommand(Js.Json.t)
  | AbstractPublishExtensionPointCommand(
      extensionPointName,
      string,
      Message.meta,
      Js.Json.t,
    )
  | AbstractCall(Message.handler(unit));

type abstractOutgoingCommandAction =
  | AbstractPublishPluginExtensionPointCommand(Js.Json.t)
  | AbstractPublishExtensionPointCommand(
      extensionPointName,
      string,
      Message.meta,
      Js.Json.t,
    )
  | AbstractCall(Message.handler(unit));

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
    (
      Message.event'(Id.String.t, ExtensionPoint.event),
      PluginSpec.pluginDefinition
    ) =>
    array(abstractIncomingCommandAction);

  let mapOutgoingEvent:
    (Js.Json.t, PluginSpec.pluginDefinition) =>
    array(abstractOutgoingCommandAction);
};

module Make =
       (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec)
       : (T with module ExtensionPoint := Spec) => {
  module Aggregate = MappingImpl.Aggregate;
  let aggregateName = Aggregate.name;
  let extensionPointName = Spec.name;

  let encodeExtensionPointCommandJson =
      (commandJson, ~from, ~extensionPointName, ~action, ~id, ~meta) => {
    let commandStr = commandJson->Js.Json.stringify;
    Js.log(
      {j|ExtensionMapping $from to ExtensionPoint $extensionPointName: $action: $commandStr id: $id|j},
    );

    [|
      ("id", id->Js.Json.string),
      ("meta", {...meta, msgId: Message.uuid()}->Message.meta_encode),
      ("command", commandJson),
    |]
    ->Js.Dict.fromArray
    ->Js.Json.object_;
  };

  let encodeExtensionPointCommand = (command, ~from, ~action, ~id, ~meta) =>
    command
    ->Spec.command_encode
    ->encodeExtensionPointCommandJson(~from, ~action, ~id, ~meta);

  let mapIncomingEvent:
    (Message.event'(Id.String.t, Spec.event), PluginSpec.pluginDefinition) =>
    array(abstractIncomingCommandAction) =
    ({Message.id, event, meta}, pluginDef) =>
      MappingImpl.mapIncomingEvent(
        id->Id.String.toString,
        event,
        meta,
        pluginDef,
      )
      ->Belt.Array.map(
          fun
          | PublishAggregateCommand(aggregateId, aggregateCmd) => {
              let commandStr =
                aggregateCmd->Aggregate.command_encode->Js.Json.stringify;
              Js.log(
                {j|ExtensionMapping incoming from ExtensionPoint $extensionPointName to Aggregate $aggregateName: Publishing command: $commandStr id: $id|j},
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
          | PublishExtensionPointCommand(id, command)
              when Spec.name == PluginExtensionPointSpec.name => {
              AbstractPublishPluginExtensionPointCommand(
                command->encodeExtensionPointCommand(
                  ~from={j|incoming from ExtensionPoint $extensionPointName|j},
                  ~extensionPointName,
                  ~action="Publish PluginExtensionPoint command",
                  ~id,
                  ~meta,
                ),
              );
            }
          | PublishExtensionPointCommand(id, command) => {
              AbstractPublishExtensionPointCommand(
                Spec.name,
                id,
                meta,
                command->encodeExtensionPointCommand(
                  ~from={j|incoming from ExtensionPoint $extensionPointName|j},
                  ~extensionPointName,
                  ~action="Forward ExtensionPoint command",
                  ~id,
                  ~meta,
                ),
              );
            }
          | ForwardCommand({extensionPointName, id, commandJson}) => {
              AbstractPublishExtensionPointCommand(
                extensionPointName,
                id,
                meta,
                commandJson->encodeExtensionPointCommandJson(
                  ~from={j|incoming from ExtensionPoint $extensionPointName|j},
                  ~extensionPointName,
                  ~action="Forward ExtensionPoint command",
                  ~id,
                  ~meta={...meta, service: extensionPointName},
                ),
              );
            }
          | Call(handler, callCommand) => {
              Js.log2(
                {j|ExtensionMapping incoming from ExtensionPoint $extensionPointName: Handling call command|j},
                callCommand->Spec.callCommand_encode->Js.Json.stringify,
              );

              AbstractCall(() => handler(callCommand));
            },
        );

  let mapOutgoingEvent:
    (Js.Json.t, PluginSpec.pluginDefinition) =>
    array(abstractOutgoingCommandAction) =
    (aggregateEvent'Json, pluginDef) =>
      switch (
        Message.event'_decode(
          Aggregate.Id.t_decode,
          Aggregate.event_decode,
          aggregateEvent'Json,
        )
      ) {
      | Ok({id, meta, event}) =>
        MappingImpl.mapOutgoingEvent(
          id->Aggregate.Id.toString,
          event,
          meta,
          pluginDef,
        )
        ->Belt.Array.map(
            fun
            | PublishExtensionPointCommand(id, command)
                when Spec.name == PluginExtensionPointSpec.name => {
                AbstractPublishPluginExtensionPointCommand(
                  command->encodeExtensionPointCommand(
                    ~from={j|outgoing from Aggregate $aggregateName|j},
                    ~extensionPointName,
                    ~action="Publish PluginExtensionPoint command",
                    ~id,
                    ~meta={...meta, service: Spec.name},
                  ),
                );
              }
            | PublishExtensionPointCommand(id, command) => {
                AbstractPublishExtensionPointCommand(
                  Spec.name,
                  id,
                  meta,
                  command->encodeExtensionPointCommand(
                    ~from={j|outgoing from Aggregate $aggregateName|j},
                    ~extensionPointName,
                    ~action="Forward ExtensionPoint command",
                    ~id,
                    ~meta={...meta, service: Spec.name},
                  ),
                );
              }
            | ForwardCommand({extensionPointName, id, commandJson}) => {
                AbstractPublishExtensionPointCommand(
                  extensionPointName,
                  id,
                  meta,
                  commandJson->encodeExtensionPointCommandJson(
                    ~from={j|outgoing from Aggregate $aggregateName|j},
                    ~extensionPointName,
                    ~action="Forward ExtensionPoint command",
                    ~id,
                    ~meta={...meta, service: extensionPointName},
                  ),
                );
              }
            | Call(handler, callCommand) => {
                Js.log2(
                  {j|ExtensionMapping outgoing from Aggregate $aggregateName: Handling call command|j},
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
