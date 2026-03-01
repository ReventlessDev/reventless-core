/**
A pre-serialized command routed to a foreign extension point.
Used when an extension needs to dispatch to an extension point it does not
own — the command JSON is forwarded opaquely without re-encoding.
*/
type forwardCommand = {
  extensionPointName: string,
  id: string,
  commandJson: JSON.t,
}

type id = string

/**
Actions returned by an extension's `mapIncomingEvent` function.

When an extension point emits an event, the extension's mapping can:
- publish a command to the aggregate it wraps (`PublishAggregateCommand`)
- publish a command back to the extension point (`PublishExtensionPointCommand`)
- forward a command to another extension point opaquely (`ForwardCommand`)
- invoke an arbitrary async callback (`Call`)
*/
type incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'msg> =
  | PublishAggregateCommand(id, 'aggregateCommand)
  | PublishAggregateCommandAsync(promise<(id, 'aggregateCommand)>)
  | PublishAggregateCommandsAsync(promise<array<(id, 'aggregateCommand)>>)
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => promise<unit>, 'msg)

/**
Actions returned by an extension's `mapOutgoingEvent` function.

When the wrapped aggregate emits an event, the extension can:
- publish a command to the extension point (`PublishExtensionPointCommand`)
- forward a command to another extension point opaquely (`ForwardCommand`)
- invoke an arbitrary async callback (`Call`)
*/
type outgoingCommandAction<'extensionPointCommand, 'msg> =
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => promise<unit>, 'msg)

/**
Maps an extension point event to actions on the wrapped aggregate or extension point.

Called when the extension point emits an event that this extension handles.
Receives the entity ID, the event, message metadata, the plugin definition,
and the query engine.
*/
type mapIncomingEvent<
  'extensionPointEvent,
  'aggregateCommand,
  'extensionPointCommand,
  'extensionPointDirective,
> = (
  string,
  'extensionPointEvent,
  Message.meta,
  Plugin.pluginDefinition,
  QueryEngine.operations,
) => array<
  incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'extensionPointDirective>,
>

/**
Maps an aggregate event to actions on the extension point.

Optionally defined — return `None` if the aggregate's outgoing events do not
need to be reflected back through the extension point.
*/
type mapOutgoingEvent<'aggregateEvent, 'extensionPointCommand, 'extensionPointDirective> = (
  string,
  'aggregateEvent,
  Message.meta,
  Plugin.pluginDefinition,
) => array<outgoingCommandAction<'extensionPointCommand, 'extensionPointDirective>>

/**
The extension point protocol that this `Extension` connects to.
Mirrors `ExtensionPoint.Spec` so the extension can be type-checked
against the extension point's command / event / directive types.
*/
module type Spec = {
  let name: string

  @schema
  type command
  @schema
  type event
  @schema
  type directive
}

/**
Application-level implementation of an extension's bidirectional mapping.

- `ExtensionPoint` — the extension point protocol this extension connects to
- `Aggregate` — the aggregate this extension wraps
- `mapIncomingEvent` — routes extension point events to aggregate / EP commands
- `mapOutgoingEvent` — optionally routes aggregate events back to the EP
*/
module type Impl = {
  module ExtensionPoint: Spec
  module Aggregate: Aggregate.Spec

  let mapIncomingEvent: mapIncomingEvent<
    ExtensionPoint.event,
    Aggregate.command,
    ExtensionPoint.command,
    ExtensionPoint.directive,
  >

  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.command, ExtensionPoint.directive>,
  >
}

/**
A dummy aggregate used when an extension does not wrap a real aggregate.
Satisfies `Aggregate.Spec` with unit command / event / error types.
*/
module NoAggregate = {
  let name = "NoAggregate"

  module Id = {
    @schema
    type t = string
    type input = string
    external make: t => t = "%identity"
    external makeFromString: string => t = "%identity"
    external toString: t => t = "%identity"
    let cmp = String.compare
  }

  @schema
  type command = unit

  @schema
  type event = unit

  @schema
  type error = unit
}
