type forwardCommand = {
  extensionPointName: string,
  id: string,
  commandJson: Js.Json.t,
}

type id = string

/* these actions are needed for Impl */
type incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'msg> =
  | PublishAggregateCommand(id, 'aggregateCommand)
  | PublishAggregateCommandAsync(Js.Promise.t<(id, 'aggregateCommand)>)
  | PublishAggregateCommandsAsync(Js.Promise.t<array<(id, 'aggregateCommand)>>)
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => Js.Promise.t<unit>, 'msg)

type outgoingCommandAction<'extensionPointCommand, 'msg> =
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => Js.Promise.t<unit>, 'msg)

type mapIncomingEvent<
  'extensionPointEvent,
  'aggregateCommand,
  'extensionPointCommand,
  'extensionPointCallCommand,
> = (
  string,
  'extensionPointEvent,
  Message.meta,
  PluginExtensionPointSpec.pluginDefinition,
  QueryEngine.t,
) => array<
  incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'extensionPointCallCommand>,
>

type mapOutgoingEvent<'aggregateEvent, 'extensionPointCommand, 'extensionPointCallCommand> = (
  string,
  'aggregateEvent,
  Message.meta,
  PluginExtensionPointSpec.pluginDefinition,
) => array<outgoingCommandAction<'extensionPointCommand, 'extensionPointCallCommand>>

module type Spec = {
  let name: string

  @decco
  type command
  @decco
  type event
  @decco
  type callCommand
}

module type Impl = {
  module ExtensionPoint: Spec
  module Aggregate: Aggregate.Spec

  let mapIncomingEvent: mapIncomingEvent<
    ExtensionPoint.event,
    Aggregate.command,
    ExtensionPoint.command,
    ExtensionPoint.callCommand,
  >

  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.command, ExtensionPoint.callCommand>,
  >
}

module NoAggregate = {
  let name = "NoAggregate"

  module Id = {
    @decco
    type t = string
    type input = string
    external make: t => t = "%identity"
    external makeFromString: string => t = "%identity"
    external toString: t => t = "%identity"
    let cmp = String.compare
  }

  @decco
  type command = unit

  @decco
  type event = unit

  @decco
  type error = unit
}
