type extensionPointName = string

/**
An async handler that may call the scheduler or query engine as a side effect.
Used as the `'msg` callback in `commandAction` and `eventAction`.
*/
type callHandler<'msg> = (
  Schedule.create,
  Schedule.delete,
  QueryEngine.operations,
  'msg,
) => promise<unit>

/**
Actions returned by `mapIncomingCommand` — what to do when the extension point
receives a command from an extension.

- `PublishCommand(id, cmd)` — publish a command to the wrapped aggregate
- `Call(handler, msg)` — invoke an async side-effect handler
*/
/* these actions are needed for Impl */
type commandAction<'command, 'msg> =
  | PublishCommand(string, 'command)
  | Call(callHandler<'msg>, 'msg)

/**
Actions returned by `mapOutgoingEvent` — what to do when the wrapped aggregate
emits an event that should be reflected through the extension point.

- `PublishEvent(id, event)` — synchronously emit an extension point event
- `PublishEventAsync(promise)` — resolve a promise and emit the resulting event
- `Call(handler, msg)` — invoke an async side-effect handler
*/
type eventAction<'event, 'msg> =
  | PublishEvent(string, 'event)
  | PublishEventAsync(promise<(string, 'event)>)
  | Call(callHandler<'msg>, 'msg)

/**
The extension point protocol — defines the command, event, and directive types
that extensions and aggregates exchange through this extension point.
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
Maps an incoming extension point command to zero or more aggregate commands
(or side-effect calls).

Called when an extension publishes a command to this extension point.
Receives the entity ID, the command, and the message metadata.
*/
type mapIncomingCommand<'extensionPointCommand, 'aggregateCommand, 'extensionPointDirective> = (
  string,
  'extensionPointCommand,
  Message.meta,
) => array<commandAction<'aggregateCommand, 'extensionPointDirective>>

/**
Maps an aggregate outgoing event to zero or more extension point events
(or side-effect calls).

Called when the wrapped aggregate emits an event. Receives the entity ID,
the event, message metadata, and the query engine.
*/
type mapOutgoingEvent<'aggregateEvent, 'extensionPointEvent, 'extensionPointDirective> = (
  string,
  'aggregateEvent,
  Message.meta,
  QueryEngine.operations,
) => array<eventAction<'extensionPointEvent, 'extensionPointDirective>>

/**
Application-level implementation of the command / event mapping for one
aggregate connected to an extension point.

Pass this to `ExtensionPointMapping.Make(Spec, Impl)` to produce a compiled
`ExtensionPointMapping.T` module.
*/
module type Impl = {
  module ExtensionPoint: Spec
  module Aggregate: Aggregate.Spec

  let mapIncomingCommand: mapIncomingCommand<
    ExtensionPoint.command,
    Aggregate.command,
    ExtensionPoint.directive,
  >

  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.event, ExtensionPoint.directive>,
  >
}

// Internal pre-compiled action types used by the ExtensionPoint runtime.
// Created by ExtensionPointMapping.Make (in reventless); consumed by ExtensionPoint_Callback
// and ExtensionPoint_Operations.

/** Internal runtime action produced after pre-encoding a `commandAction`. Not for direct use. */
type abstractCommandAction =
  | AbstractPublishCommand(string, string, Message.commandJson)
  | AbstractCall(string, unit => promise<unit>)

/** Internal runtime action produced after pre-encoding an `eventAction`. Not for direct use. */
type abstractEventAction<'extensionPointEvent> =
  | AbstractPublishEvent(string, Message.meta, JSON.t)
  | AbstractPublishEventAsync(promise<(string, Message.meta, JSON.t)>)
  | AbstractCall(unit => promise<unit>)

/**
A pre-compiled mapping module produced by `ExtensionPointMapping.Make(Spec, Impl)`.

The runtime uses `mapIncomingCommands` and `mapOutgoingEvent` to dispatch commands
and events without knowing the concrete extension point or aggregate types.
Application developers call `Make` themselves; the result satisfies this type.
*/
// Pre-compiled mapping module type. Created by ExtensionPointMapping.Make(Spec, Impl).
// App developers call Make themselves; the result satisfies this type.
module type T = {
  module ExtensionPoint: Spec

  /** Name of the aggregate this mapping connects to the extension point. */
  let aggregateName: string

  /**
  Converts a batch of typed extension point commands into pre-encoded abstract actions.
  Called by the extension point runtime for each incoming command batch.
  */
  let mapIncomingCommands: (
    array<CommandTopic.topicItem<Message.command'<Id.String.t, ExtensionPoint.command>>>,
    Schedule.create,
    Schedule.delete,
    QueryEngine.operations,
  ) => array<abstractCommandAction>

  /**
  Converts a raw aggregate event JSON into pre-encoded abstract event actions.
  `None` if this mapping does not produce outgoing extension point events.
  */
  let mapOutgoingEvent: option<
    (
      JSON.t,
      Schedule.create,
      Schedule.delete,
      QueryEngine.operations,
    ) => array<abstractEventAction<ExtensionPoint.event>>,
  >
}

module Make = (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec): (
  T with module ExtensionPoint := Spec
) => {
  module Aggregate = MappingImpl.Aggregate
  let aggregateName = Aggregate.name
  let extensionPointName = Spec.name

  let doMapIncomingCommands = (
    mapIncomingEventImpl,
    topicItems,
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) =>
    topicItems
    ->Array.map(({CommandTopic.reference: reference, command: {Message.id: id, command, meta}}) =>
      mapIncomingEventImpl(id->Id.String.toString, command, meta)->Array.map(x =>
        switch x {
        | PublishCommand(aggregateId, aggregateCmd) =>
          let commandStr = aggregateCmd->Message.encode(Aggregate.commandSchema)->JSON.stringify
          Console.log(
            `ExtensionPointMapping incoming from ExtensionPoint ${extensionPointName} to Aggregate ${aggregateName}: Publishing command: ${commandStr} id: ${aggregateId}`,
          )

          AbstractPublishCommand(
            aggregateName,
            reference,
            {
              id: aggregateId,
              meta: {
                ...meta,
                service: Aggregate.name,
                msgId: Message.uuid(),
              },
              commandJson: aggregateCmd->Message.encode(Aggregate.commandSchema),
            },
          )
        | Call(handler, directive) =>
          Console.log2(
            `ExtensionPointMapping incoming from ExtensionPoint ${extensionPointName}: Handling directive`,
            directive->Message.encode(Spec.directiveSchema)->JSON.stringify,
          )

          AbstractCall(
            reference,
            () => handler(createSchedule, deleteSchedule, queryEngine, directive),
          )
        }
      )
    )
    ->Array.flat

  let mapIncomingCommands = doMapIncomingCommands(MappingImpl.mapIncomingCommand, ...)

  let doMapOutgoingEvent = (
    mapOutgoingEventImpl,
    aggregateEventJson',
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) =>
    switch aggregateEventJson'->Message.decodeEvent'(Aggregate.Id.schema, Aggregate.eventSchema) {
    | {id, meta, event} =>
      mapOutgoingEventImpl(
        id->Aggregate.Id.toString,
        event,
        meta,
        queryEngine,
      )->Array.map(eventAction =>
        switch eventAction {
        | PublishEvent(id, event) =>
          let eventJson = event->Message.encode(Spec.eventSchema)
          Console.log(
            `ExtensionPointMapping: outgoing from Aggregate ${aggregateName} to ExtensionPoint ${extensionPointName}: Publishing event: ${eventJson->JSON.stringify} id: ${id}`,
          )
          let meta = {
            ...meta,
            service: Spec.name,
            msgId: Message.uuid(),
          }
          let eventJson' = Message.composeEventJson'(id, meta, eventJson)
          AbstractPublishEvent(id, meta, eventJson')
        | PublishEventAsync(promise) =>
          let toEvent' = async promise => {
            let (id, event) = await promise
            let eventJson = event->Message.encode(Spec.eventSchema)
            Console.log(
              `ExtensionPointMapping: async outgoing from Aggregate ${aggregateName} to ExtensionPoint ${extensionPointName}: Publishing event: ${eventJson->JSON.stringify} id: ${id}`,
            )
            let eventJson' = Message.composeEventJson'(id, meta, eventJson) // TODO: check if meta is correct
            (id, meta, eventJson')
          }
          AbstractPublishEventAsync(promise->toEvent')
        | Call(handler, directive) =>
          Console.log2(
            `ExtensionPointMapping: outgoing from Aggregate ${aggregateName}: Handling directive`,
            directive->Message.encode(Spec.directiveSchema)->JSON.stringify,
          )

          AbstractCall(() => handler(createSchedule, deleteSchedule, queryEngine, directive))
        }
      )
    | exception err =>
      Console.log2("ExtensionPointMapping.mapOutgoing: Error: Decode failure: ", err)
      []
    }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
