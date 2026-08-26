type extensionPointName = string

/** An async handler for a typed directive, used by `HandleDirective` on both
    `commandAction` and `eventAction`. */
type directiveHandler<'directive> = (
  Reventless.Schedule.create,
  Reventless.Schedule.delete,
  Reventless.QueryEngine.operations,
  'directive,
) => promise<unit>

/** What `mapIncomingCommand` can do with a command an extension published:
    publish one to the wrapped aggregate, or run a directive handler. */
type commandAction<'command, 'directive> =
  | PublishCommand(string, 'command)
  | HandleDirective(directiveHandler<'directive>, 'directive)

/** What `mapOutgoingEvent` can do with a Delegate event: publish an EP event,
    publish one behind a promise, or run a directive handler. */
type eventAction<'event, 'directive> =
  | PublishEvent(string, 'event)
  | PublishEventAsync(promise<(string, 'event)>)
  | HandleDirective(directiveHandler<'directive>, 'directive)

/** The extension point protocol: the command, event and directive types crossing it. */
module type Spec = {
  let name: string
  let moduleUrl: string

  @schema
  type command
  @schema
  type event
  @schema
  type directive
}

/** Maps a command an extension published to zero or more aggregate commands. */
type mapIncomingCommand<'extensionPointCommand, 'aggregateCommand, 'extensionPointDirective> = (
  string,
  'extensionPointCommand,
  Reventless.Message.meta,
) => array<commandAction<'aggregateCommand, 'extensionPointDirective>>

/** Maps an aggregate event to zero or more extension point events. */
type mapOutgoingEvent<'aggregateEvent, 'extensionPointEvent, 'extensionPointDirective> = (
  string,
  'aggregateEvent,
  Reventless.Message.meta,
  Reventless.QueryEngine.operations,
) => array<eventAction<'extensionPointEvent, 'extensionPointDirective>>

/** One published event of this port and the `Delegate` events producing it. Bare
    constructor names, qualified downstream by `Plugin_Structure`. Per published
    event, so many-to-one — the case a port exists for — reads naturally. */
type publishedEvent = {
  name: string,
  fromEventTypes: array<string>,
}

/** One aggregate's mapping to an extension point. Pass to
    `ExtensionPointMapping.Make` for the compiled `T`. */
module type Mapping = {
  module ExtensionPoint: Spec
  module Delegate: Reventless.Aggregate.Spec

  // The mapping file's own url, not the spec's — the EventCollector runtime
  // dynamic-imports mapOutgoingEvent from it. Injected by `@@reventless.spec`.
  let moduleUrl: string

  let mapIncomingCommand: mapIncomingCommand<
    ExtensionPoint.command,
    Delegate.command,
    ExtensionPoint.directive,
  >

  let mapOutgoingEvent: option<
    mapOutgoingEvent<Delegate.event, ExtensionPoint.event, ExtensionPoint.directive>,
  >

  /** The port's translation table — see `publishedEvent`. Derived by the PPX from
      `mapOutgoingEvent`'s own arms; write it by hand only where it says it cannot. */
  let publishedEvents: array<publishedEvent>
}

// Pre-compiled action types: made by Make, consumed by ExtensionPoint_Callback
// and ExtensionPoint_Operations.

/** Internal runtime action produced after pre-encoding a `commandAction`. Not for direct use. */
type abstractCommandAction =
  | AbstractPublishCommand(string, string, Reventless.Message.commandJson)
  | AbstractHandleDirective(string, unit => promise<unit>)

/** Internal runtime action produced after pre-encoding an `eventAction`. Not for direct use. */
type abstractEventAction<'extensionPointEvent> =
  | AbstractPublishEvent(string, Reventless.Message.meta, JSON.t)
  | AbstractPublishEventAsync(promise<(string, Reventless.Message.meta, JSON.t)>)
  | AbstractHandleDirective(unit => promise<unit>)

/** A compiled mapping, produced by `Make`. Lets the runtime dispatch without
    knowing the concrete extension point or aggregate types. */
module type T = {
  module ExtensionPoint: Spec

  /** Name of the target this mapping connects to the extension point. */
  let delegateName: string

  /** Pre-encodes a batch of typed EP commands for the runtime. */
  let mapIncomingCommands: (
    array<CommandTopic.topicItem<Reventless.Message.command'<Reventless.Id.String.t, ExtensionPoint.command>>>,
    Reventless.Schedule.create,
    Reventless.Schedule.delete,
    Reventless.QueryEngine.operations,
  ) => array<abstractCommandAction>

  /** Pre-encodes a raw aggregate event JSON. `None` if nothing is published out. */
  let mapOutgoingEvent: option<
    (
      JSON.t,
      Reventless.Schedule.create,
      Reventless.Schedule.delete,
      Reventless.QueryEngine.operations,
    ) => array<abstractEventAction<ExtensionPoint.event>>,
  >
}

module Make = (MappingImpl: Mapping): (
  T with module ExtensionPoint := MappingImpl.ExtensionPoint
) => {
  module Spec = MappingImpl.ExtensionPoint
  module Delegate = MappingImpl.Delegate
  let delegateName = Delegate.name
  let extensionPointName = Spec.name

  // Pre-filter for incoming envelopes: sibling variants the Delegate did not
  // declare are skipped undecoded. Payload-less variants included — the
  // envelope's `event` TAG still carries their name.
  let acceptedTags = Reventless.DcbTag.extractAllVariantNames(Delegate.eventSchema)

  // `comp` as an Effect log annotation; EffectLogger.install lifts it to the
  // top-level JSON field.
  let compLog = (comp, msg) =>
    Effect.logInfo(msg)->Effect.annotateLogs("comp", comp)->Effect.runSync

  let doMapIncomingCommands = (
    mapIncomingEventImpl,
    topicItems,
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) =>
    topicItems
    ->Array.map(({CommandTopic.reference: reference, command: {Reventless.Message.id: id, command, meta}}) =>
      mapIncomingEventImpl(id->Reventless.Id.String.toString, command, meta)->Array.map(x =>
        switch x {
        | PublishCommand(targetId, targetCmd) =>
          let cmdJson = targetCmd->Reventless.Message.encode(Delegate.commandSchema)
          compLog(`ExtensionPoint(${extensionPointName})`, `EP→${delegateName}: ${cmdJson->Reventless.Message.variantNameOfJson->Reventless.AnsiStyle.bold}(${targetId})`)

          AbstractPublishCommand(
            delegateName,
            reference,
            {
              id: targetId,
              meta: {
                ...meta,
                service: Delegate.name,
                msgId: Message.uuid(),
              },
              commandJson: targetCmd->Reventless.Message.encode(Delegate.commandSchema),
            },
          )
        | HandleDirective(handler, directive) =>
          compLog(`ExtensionPoint(${extensionPointName})`, "incoming directive")

          AbstractHandleDirective(
            reference,
            () => handler(createSchedule, deleteSchedule, queryEngine, directive),
          )
        }
      )
    )
    ->Array.flat

  let mapIncomingCommands = doMapIncomingCommands(MappingImpl.mapIncomingCommand, ...)

  let variantTagOfEnvelope = json =>
    json
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("event"))
    ->Option.map(Reventless.Message.variantNameOfJson)
    ->Option.getOr("unknown")

  let doMapOutgoingEvent = (
    mapOutgoingEventImpl,
    targetEventJson',
    createSchedule,
    deleteSchedule,
    queryEngine,
  ) => {
    let tag = variantTagOfEnvelope(targetEventJson')
    // Not this mapping's concern — skip without decoding.
    if !(acceptedTags->Array.includes(tag)) {
      []
    } else {
      let {id, meta, event} =
        targetEventJson'->Reventless.Message.decodeEvent'(
          Delegate.Id.schema,
          Delegate.eventSchema,
        )
      mapOutgoingEventImpl(
        id->Delegate.Id.toString,
        event,
        meta,
        queryEngine,
      )->Array.map(eventAction =>
        switch eventAction {
        | PublishEvent(id, event) =>
          let eventJson = event->Reventless.Message.encode(Spec.eventSchema)
          compLog(`ExtensionPoint(${extensionPointName})`, `mapped ${delegateName} → ${eventJson->Reventless.Message.variantNameOfJson->Reventless.AnsiStyle.bold}(${id})`)
          let meta = {
            ...meta,
            service: Spec.name,
            msgId: Message.uuid(),
          }
          let eventJson' = Reventless.Message.composeEventJson'(id, meta, eventJson)
          AbstractPublishEvent(id, meta, eventJson')
        | PublishEventAsync(promise) =>
          let toEvent' = async promise => {
            let (id, event) = await promise
            let eventJson = event->Reventless.Message.encode(Spec.eventSchema)
            compLog(`ExtensionPoint(${extensionPointName})`, `mapped ${delegateName} → ${eventJson->Reventless.Message.variantNameOfJson->Reventless.AnsiStyle.bold}(${id}) (async)`)
            let eventJson' = Reventless.Message.composeEventJson'(id, meta, eventJson) // TODO: check if meta is correct
            (id, meta, eventJson')
          }
          AbstractPublishEventAsync(promise->toEvent')
        | HandleDirective(handler, directive) =>
          compLog(`ExtensionPoint(${extensionPointName})`, `mapped ${delegateName} → directive`)

          AbstractHandleDirective(() =>
            handler(createSchedule, deleteSchedule, queryEngine, directive)
          )
        }
      )
    }
  }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
