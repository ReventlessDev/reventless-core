type extensionPointName = string

type callHandler<'msg> = (
  Schedule.create,
  Schedule.delete,
  QueryEngine.operations,
  'msg,
) => promise<unit>

/* these actions are needed for Impl */
type commandAction<'command, 'msg> =
  | PublishCommand(string, 'command)
  | Call(callHandler<'msg>, 'msg)

type eventAction<'event, 'msg> =
  | PublishEvent(string, 'event)
  | PublishEventAsync(promise<(string, 'event)>)
  | Call(callHandler<'msg>, 'msg)

module type Spec = {
  let name: string

  @schema
  type command
  @schema
  type event
  @schema
  type callCommand
}

type mapIncomingCommand<'extensionPointCommand, 'aggregateCommand, 'extensionPointCallCommand> = (
  string,
  'extensionPointCommand,
  Message.meta,
) => array<commandAction<'aggregateCommand, 'extensionPointCallCommand>>

type mapOutgoingEvent<'aggregateEvent, 'extensionPointEvent, 'extensionPointCallCommand> = (
  string,
  'aggregateEvent,
  Message.meta,
  QueryEngine.operations,
) => array<eventAction<'extensionPointEvent, 'extensionPointCallCommand>>

module type Impl = {
  module ExtensionPoint: Spec
  module Aggregate: Aggregate.Spec

  let mapIncomingCommand: mapIncomingCommand<
    ExtensionPoint.command,
    Aggregate.command,
    ExtensionPoint.callCommand,
  >

  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.event, ExtensionPoint.callCommand>,
  >
}
