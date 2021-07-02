type extensionPointName = string;

type callHandler('msg) =
  (Schedule.create, Schedule.delete, ReventlessSpec.QueryEngine.t, 'msg) =>
  Js.Promise.t(unit);

/* these actions are needed for Impl */
type commandAction('command, 'msg) =
  | PublishCommand(string, 'command)
  | Call(callHandler('msg), 'msg);

type eventAction('event, 'msg) =
  | PublishEvent(string, 'event)
  | PublishEventAsync(Js.Promise.t((string, 'event)))
  | Call(callHandler('msg), 'msg);

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
  'aggregateCommand,
  'extensionPointCallCommand,
) =
  (string, 'extensionPointCommand, Message.meta) =>
  array(commandAction('aggregateCommand, 'extensionPointCallCommand));

type mapOutgoingEvent(
  'aggregateEvent,
  'extensionPointEvent,
  'extensionPointCallCommand,
) =
  (string, 'aggregateEvent, Message.meta, ReventlessSpec.QueryEngine.t) =>
  array(eventAction('extensionPointEvent, 'extensionPointCallCommand));

module type Impl = {
  module ExtensionPoint: Spec;
  module Aggregate: ReventlessSpec.AggregateSpec.T;

  let mapIncomingCommand:
    mapIncomingCommand(
      ExtensionPoint.command,
      Aggregate.command,
      ExtensionPoint.callCommand,
    );

  let mapOutgoingEvent:
    mapOutgoingEvent(
      Aggregate.event,
      ExtensionPoint.event,
      ExtensionPoint.callCommand,
    );
};