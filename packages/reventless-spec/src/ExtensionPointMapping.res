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

// Internal pre-compiled action types used by the ExtensionPoint runtime.
// Created by ExtensionPointMapping.Make (in reventless); consumed by ExtensionPoint_Callback
// and ExtensionPoint_Operations.
type abstractCommandAction =
  | AbstractPublishCommand(string, string, Message.commandJson)
  | AbstractCall(string, unit => promise<unit>)

type abstractEventAction<'extensionPointEvent> =
  | AbstractPublishEvent(string, Message.meta, JSON.t)
  | AbstractPublishEventAsync(promise<(string, Message.meta, JSON.t)>)
  | AbstractCall(unit => promise<unit>)

// Pre-compiled mapping module type. Created by ExtensionPointMapping.Make(Spec, Impl).
// App developers call Make themselves; the result satisfies this type.
module type T = {
  module ExtensionPoint: Spec

  let aggregateName: string

  let mapIncomingCommands: (
    array<CommandTopic.topicItem<Message.command'<Id.String.t, ExtensionPoint.command>>>,
    Schedule.create,
    Schedule.delete,
    QueryEngine.operations,
  ) => array<abstractCommandAction>

  let mapOutgoingEvent: option<
    (
      JSON.t,
      Schedule.create,
      Schedule.delete,
      QueryEngine.operations,
    ) => array<abstractEventAction<ExtensionPoint.event>>,
  >
}
