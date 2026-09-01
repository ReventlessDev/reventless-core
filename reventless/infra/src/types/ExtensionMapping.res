/** A command routed to an extension point this extension does not own —
    forwarded opaquely, without re-encoding. */
type forwardCommand = {
  extensionPointName: string,
  id: string,
  commandJson: JSON.t,
}

type id = string

/** What `mapIncomingEvent` can do with a published event: command the wrapped
    aggregate or slice, command the extension point, forward, or run a directive.
    The slice forms take no id — the FIFO group comes from `@partitionTag`. */
type incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'directive> =
  | PublishAggregateCommand(id, 'aggregateCommand)
  | PublishAggregateCommandAsync(promise<(id, 'aggregateCommand)>)
  | PublishAggregateCommandsAsync(promise<array<(id, 'aggregateCommand)>>)
  | PublishStateChangeSliceCommand('aggregateCommand)
  | PublishStateChangeSliceCommandAsync(promise<'aggregateCommand>)
  | PublishStateChangeSliceCommandsAsync(promise<array<'aggregateCommand>>)
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | HandleDirective(Reventless.Handler.handler<'directive>, 'directive)

/** What `mapOutgoingEvent` can do with a delegate event: command the extension
    point, forward, or run a directive. */
type outgoingCommandAction<'extensionPointCommand, 'directive> =
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | HandleDirective(Reventless.Handler.handler<'directive>, 'directive)

/** Maps a published event to actions on the wrapped delegate or the extension point. */
type mapIncomingEvent<
  'extensionPointEvent,
  'aggregateCommand,
  'extensionPointCommand,
  'extensionPointDirective,
> = (
  string,
  'extensionPointEvent,
  Reventless.Message.meta,
  Reventless.Plugin.pluginDefinition,
  Reventless.QueryEngine.operations,
) => array<
  incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'extensionPointDirective>,
>

/** Maps a delegate event back to actions on the extension point. `None` when
    nothing flows back. */
type mapOutgoingEvent<'aggregateEvent, 'extensionPointCommand, 'extensionPointDirective> = (
  string,
  'aggregateEvent,
  Reventless.Message.meta,
  Reventless.Plugin.pluginDefinition,
) => array<outgoingCommandAction<'extensionPointCommand, 'extensionPointDirective>>

/** The extension point protocol this `Extension` connects to — mirrors
    `ExtensionPoint.Spec` so the mapping type-checks against it. */
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

/** One published event this extension handles and the commands it routes to —
    the subscriber's half of `ExtensionPointMapping.publishedEvent`. Bare names,
    resolved against the `Delegate`'s commands first, the EP's second. */
type handledEvent = {
  name: string,
  toCommandTypes: array<string>,
}

/** One command this extension sends back to the port and the `Delegate` events
    producing it — the subscriber's half of `ExtensionPointMapping.acceptedCommand`.
    Read off `mapOutgoingEvent` only: an EP command published from an arm of
    `mapIncomingEvent` is an event→command edge and stays in `handledEvent`. */
type issuedCommand = {
  name: string,
  fromEventTypes: array<string>,
}

/** An extension's bidirectional mapping between one extension point and one
    delegate (aggregate or DCB slice). */
module type Mapping = {
  module ExtensionPoint: Spec
  module Delegate: Reventless.Aggregate.Spec

  // The extension file's own url — dynamic-imported at runtime to reconstruct the
  // two mapping functions. Injected by `@@reventless.extension`.
  let moduleUrl: string

  // The Delegate's url — the EventCollector imports its spec at cold start, since
  // the compiled export erases `Mapping.Delegate`.
  let delegateModuleUrl: string

  let mapIncomingEvent: mapIncomingEvent<
    ExtensionPoint.event,
    Delegate.command,
    ExtensionPoint.command,
    ExtensionPoint.directive,
  >

  let mapOutgoingEvent: option<
    mapOutgoingEvent<Delegate.event, ExtensionPoint.command, ExtensionPoint.directive>,
  >

  /** Which published event routes to which commands — see `handledEvent`. Derived
      by the PPX from `mapIncomingEvent`'s arms; hand-written only where it says
      it cannot read them. */
  let handledEvents: array<handledEvent>

  /** Which commands travel back to the port — see `issuedCommand`. Derived from
      `mapOutgoingEvent`'s arms, under the same rule. */
  let issuedCommands: array<issuedCommand>
}

/** A stand-in for an extension that wraps no aggregate or slice. */
module NoDelegate = {
  let name = "NoDelegate"

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

  let commandSchema = S.unit
  let moduleUrl: string = %raw(`import.meta.url`)
  let commandAuthorization = (_: command): Reventless.Authorization.permission =>
    AllowAuthenticated
  type lifecycleState = unit
  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
}


open PluginExtensionPointSpec

type extensionPointName = string

/* these actions are internal to the Mapping Functor */
type abstractIncomingCommandAction =
  | AbstractPublishAggregateCommand(string, Reventless.Message.commandJson)
  | AbstractPublishAggregateCommandAsync(promise<(string, Reventless.Message.commandJson)>)
  | AbstractPublishAggregateCommandsAsync(promise<array<(string, Reventless.Message.commandJson)>>)
  | AbstractPublishPluginExtensionPointCommand(Reventless.Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Reventless.Message.commandJson)
  | AbstractHandleDirective(Reventless.Handler.handler<unit>)

type abstractOutgoingCommandAction =
  | AbstractPublishPluginExtensionPointCommand(Reventless.Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Reventless.Message.commandJson)
  | AbstractHandleDirective(Reventless.Handler.handler<unit>)

module type T = {
  module ExtensionPoint: Spec

  let delegateName: string

  // All carried through the functor: `Plugin_Structure` sees an extension only
  // compiled, and `T` erases the Delegate's types, so the checks against the two
  // tables need its command and event names rather than its schemas.
  let handledEvents: array<handledEvent>
  let issuedCommands: array<issuedCommand>
  let delegateCommandNames: array<string>
  let delegateEventNames: array<string>

  let mapIncomingEvent: (
    Reventless.Message.event'<string, ExtensionPoint.event>,
    pluginDefinition,
    Reventless.QueryEngine.operations,
  ) => array<abstractIncomingCommandAction>

  let mapOutgoingEvent: option<(JSON.t, pluginDefinition) => array<abstractOutgoingCommandAction>>
}

module type Mappings = {
  module Spec: Spec
  module type Mapping = T with module ExtensionPoint := Spec
  let name: string
  let moduleUrl: string
  let mappings: array<module(Mapping)>
}

module Make = (MappingImpl: Mapping): (
  T with module ExtensionPoint := MappingImpl.ExtensionPoint
) => {
  module Spec = MappingImpl.ExtensionPoint
  module Delegate = MappingImpl.Delegate
  let delegateName = Delegate.name
  let extensionPointName = Spec.name
  let handledEvents = MappingImpl.handledEvents
  let issuedCommands = MappingImpl.issuedCommands
  let delegateCommandNames = Reventless.DcbTag.extractAllVariantNames(Delegate.commandSchema)

  // Pre-filter for incoming envelopes: sibling variants the Delegate did not
  // declare are skipped undecoded. Payload-less variants included — the
  // envelope's `event` TAG still carries their name.
  let acceptedTags = Reventless.DcbTag.extractAllVariantNames(Delegate.eventSchema)
  let delegateEventNames = acceptedTags

  // Partition tag for `PublishStateChangeSliceCommand*`. Throws when the Delegate
  // declares none — an Aggregate, where `PublishAggregateCommand` is the right form.
  let derivedPartitionTagLazy = ref(None)
  let getDerivedPartitionTag = () =>
    switch derivedPartitionTagLazy.contents {
    | Some(d) => d
    | None =>
      let d = Reventless.DcbTag.derivePartitionTag([
        (Delegate.name, Delegate.moduleUrl, Delegate.commandSchema->S.castToUnknown),
      ])
      derivedPartitionTagLazy := Some(d)
      d
    }
  let derivePartitionId = (targetCmd: Delegate.command): string =>
    switch getDerivedPartitionTag() {
    | Simple(pt) =>
      let tags = Reventless.DcbTag.extractTags(Delegate.commandSchema, targetCmd)
      Reventless.DcbTag.getPartitionTagValue([{tags: tags}], pt)->Option.getOr("")
    | Composite(spec) =>
      let tags = Reventless.DcbTag.extractTags(Delegate.commandSchema, targetCmd)
      Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec)
    }

  // `comp` as an Effect log annotation; EffectLogger.install lifts it to the
  // top-level JSON field.
  let compLog = (comp, msg) =>
    Effect.logInfo(msg)->Effect.annotateLogs("comp", comp)->Effect.runSync

  let encodeMeta = (meta: Reventless.Message.meta, service) => {
    ...meta,
    service,
    msgId: Message.uuid(),
  }

  let doMapIncomingEvent = (
    mapIncomingEventImpl,
    {Reventless.Message.id: id, event, meta},
    pluginDef,
    queryEngine,
  ) => {
    let encodeTargetCommandJson = (targetCmd, targetId) => {
      let cmdJson = targetCmd->Reventless.Message.encode(Delegate.commandSchema)
      {
        Reventless.Message.id: targetId,
        meta: encodeMeta(meta, delegateName),
        commandJson: cmdJson,
      }
    }

    let encodeExtensionPointCommandJson = (commandJson, ~id, ~extensionPointName, ~action) => {
      compLog(`Extension(${extensionPointName})`, `${action}: ${commandJson->Reventless.Message.variantNameOfJson->Reventless.AnsiStyle.bold}(${id})`)
      {
        Reventless.Message.id,
        meta: encodeMeta(meta, extensionPointName),
        commandJson,
      }
    }

    let encodeExtensionPointCommand = (command, ~id, ~extensionPointName, ~action) =>
      command
      ->Reventless.Message.encode(Spec.commandSchema)
      ->encodeExtensionPointCommandJson(~id, ~extensionPointName, ~action)

    mapIncomingEventImpl(id, event, meta, pluginDef, queryEngine)->Array.map(x =>
      switch x {
      | PublishAggregateCommand(targetId, targetCmd) =>
        AbstractPublishAggregateCommand(
          delegateName,
          targetCmd->encodeTargetCommandJson(targetId),
        )
      | PublishAggregateCommandAsync(promise) =>
        let toCommandJson = async promise => {
          let (targetId, targetCmd) = await promise
          (delegateName, targetCmd->encodeTargetCommandJson(targetId))
        }
        AbstractPublishAggregateCommandAsync(promise->toCommandJson)
      | PublishAggregateCommandsAsync(promise) =>
        let toCommandJsons = async promise =>
          (await promise)->Array.map(((targetId, targetCmd)) => (
            delegateName,
            targetCmd->encodeTargetCommandJson(targetId),
          ))
        AbstractPublishAggregateCommandsAsync(promise->toCommandJsons)
      | PublishStateChangeSliceCommand(targetCmd) =>
        AbstractPublishAggregateCommand(
          delegateName,
          targetCmd->encodeTargetCommandJson(derivePartitionId(targetCmd)),
        )
      | PublishStateChangeSliceCommandAsync(promise) =>
        let toCommandJson = async promise => {
          let targetCmd = await promise
          (delegateName, targetCmd->encodeTargetCommandJson(derivePartitionId(targetCmd)))
        }
        AbstractPublishAggregateCommandAsync(promise->toCommandJson)
      | PublishStateChangeSliceCommandsAsync(promise) =>
        let toCommandJsons = async promise =>
          (await promise)->Array.map(targetCmd => (
            delegateName,
            targetCmd->encodeTargetCommandJson(derivePartitionId(targetCmd)),
          ))
        AbstractPublishAggregateCommandsAsync(promise->toCommandJsons)
      | PublishExtensionPointCommand(id, command)
        if Spec.name == PluginExtensionPointSpec.name =>
        AbstractPublishPluginExtensionPointCommand(
          command->encodeExtensionPointCommand(
            ~id,
            ~extensionPointName,
            ~action="Publish PluginExtensionPoint command",
          ),
        )
      | PublishExtensionPointCommand(id, command) =>
        AbstractPublishExtensionPointCommand(
          extensionPointName,
          command->encodeExtensionPointCommand(
            ~id,
            ~extensionPointName,
            ~action="Publish ExtensionPoint command",
          ),
        )
      | ForwardCommand({extensionPointName, id, commandJson}) =>
        AbstractPublishExtensionPointCommand(
          extensionPointName,
          commandJson->encodeExtensionPointCommandJson(
            ~id,
            ~extensionPointName,
            ~action="Forward ExtensionPoint command",
          ),
        )
      | HandleDirective(handler, directive) =>
        compLog(`Extension(${extensionPointName})`, "incoming directive")
        AbstractHandleDirective(() => handler(directive))
      }
    )
  }

  let mapIncomingEvent = doMapIncomingEvent(MappingImpl.mapIncomingEvent, ...)

  let variantTagOfEnvelope = json =>
    json
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("event"))
    ->Option.map(Reventless.Message.variantNameOfJson)
    ->Option.getOr("unknown")

  let doMapOutgoingEvent = (mapOutgoingEventImpl, targetEvent'Json, pluginDef) => {
    let tag = variantTagOfEnvelope(targetEvent'Json)
    // Not this mapping's concern — skip without decoding.
    if !(acceptedTags->Array.includes(tag)) {
      []
    } else {
      let {id, meta, event} =
        targetEvent'Json->Reventless.Message.decodeEvent'(
          Delegate.Id.schema,
          Delegate.eventSchema,
        )
      let encodeExtensionPointCommandJson = (commandJson, ~id, ~extensionPointName, ~action) => {
        compLog(`Extension(${delegateName})`, `${action}: ${commandJson->Reventless.Message.variantNameOfJson->Reventless.AnsiStyle.bold}(${id})`)
        {
          Reventless.Message.id,
          meta: encodeMeta(meta, extensionPointName),
          commandJson,
        }
      }

      let encodeExtensionPointCommand = (command, ~id, ~extensionPointName, ~action) =>
        command
        ->Reventless.Message.encode(Spec.commandSchema)
        ->encodeExtensionPointCommandJson(~id, ~extensionPointName, ~action)

      mapOutgoingEventImpl(id->Delegate.Id.toString, event, meta, pluginDef)->Array.map(x =>
        switch x {
        | PublishExtensionPointCommand(id, command)
          if Spec.name == PluginExtensionPointSpec.name =>
          AbstractPublishPluginExtensionPointCommand(
            command->encodeExtensionPointCommand(
              ~id,
              ~extensionPointName,
              ~action="Publish PluginExtensionPoint command",
            ),
          )

        | PublishExtensionPointCommand(id, command) =>
          AbstractPublishExtensionPointCommand(
            extensionPointName,
            command->encodeExtensionPointCommand(
              ~id,
              ~extensionPointName,
              ~action="Publish ExtensionPoint command",
            ),
          )
        | ForwardCommand({extensionPointName, id, commandJson}) =>
          AbstractPublishExtensionPointCommand(
            extensionPointName,
            commandJson->encodeExtensionPointCommandJson(
              ~id,
              ~extensionPointName,
              ~action="Forward ExtensionPoint command",
            ),
          )
        | HandleDirective(handler, directive) =>
          compLog(`Extension(${delegateName})`, "outgoing directive")
          AbstractHandleDirective(() => handler(directive))
        }
      )
    }
  }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
