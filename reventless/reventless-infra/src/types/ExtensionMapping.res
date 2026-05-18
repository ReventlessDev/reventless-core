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
- publish a command to the StateChangeSlice it wraps (`PublishStateChangeSliceCommand`)
  — no id argument; the framework derives the FIFO grouping id from the command's
  `@partitionTag` (or `@compositePartitionTag`) field.
- publish a command back to the extension point (`PublishExtensionPointCommand`)
- forward a command to another extension point opaquely (`ForwardCommand`)
- invoke an arbitrary async callback (`Call`)
*/
type incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'msg> =
  | PublishAggregateCommand(id, 'aggregateCommand)
  | PublishAggregateCommandAsync(promise<(id, 'aggregateCommand)>)
  | PublishAggregateCommandsAsync(promise<array<(id, 'aggregateCommand)>>)
  | PublishStateChangeSliceCommand('aggregateCommand)
  | PublishStateChangeSliceCommandAsync(promise<'aggregateCommand>)
  | PublishStateChangeSliceCommandsAsync(promise<array<'aggregateCommand>>)
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
  Reventless.Message.meta,
  Reventless.Plugin.pluginDefinition,
  Reventless.QueryEngine.operations,
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
  Reventless.Message.meta,
  Reventless.Plugin.pluginDefinition,
) => array<outgoingCommandAction<'extensionPointCommand, 'extensionPointDirective>>

/**
The extension point protocol that this `Extension` connects to.
Mirrors `ExtensionPoint.Spec` so the extension can be type-checked
against the extension point's command / event / directive types.
*/
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

/**
Application-level implementation of an extension's bidirectional mapping.

- `ExtensionPoint` — the extension point protocol this extension connects to
- `Delegate` — the component this extension delegates to (aggregate or DCB slice)
- `mapIncomingEvent` — routes extension point events to delegate commands
- `mapOutgoingEvent` — optionally routes delegate events back to the EP
*/
module type Mapping = {
  module ExtensionPoint: Spec
  module Delegate: Reventless.Aggregate.Spec

  // npm-style specifier of the user extension file (the module exporting this
  // Mapping). Used by Plugin_Helpers + the bundled Plugin EventCollector entry
  // point to dynamic-import the user mapping for runtime reconstruction of
  // mapIncomingEvent / mapOutgoingEvent. PPX-injected on @@reventless.extension
  // files as the same specifier as the file-level moduleUrl.
  let moduleUrl: string

  // npm-style specifier of the Delegate's source module. Used by the bundled
  // Plugin EventCollector entry point to dynamic-import the Delegate spec at
  // cold start (Mapping.ExtensionPoint and Mapping.Delegate are erased in the
  // compiled .res.mjs export). PPX-injected on @@reventless.extension files
  // as `Delegate.moduleUrl`.
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
}

/**
A dummy target used when an extension does not wrap a real aggregate or slice.
Satisfies `Aggregate.Spec` with unit command / event / error types.
*/
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
  | AbstractCall(Reventless.Handler.handler<unit>)

type abstractOutgoingCommandAction =
  | AbstractPublishPluginExtensionPointCommand(Reventless.Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Reventless.Message.commandJson)
  | AbstractCall(Reventless.Handler.handler<unit>)

module type T = {
  module ExtensionPoint: Spec

  let delegateName: string

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

  // Variant TAGs the Delegate cares about — derived from the Delegate's event
  // schema at functor instantiation. Used to pre-filter incoming envelopes:
  // sibling variants on the source log (events the Delegate did not declare)
  // are silently skipped without any decode attempt.
  // extractAllVariantNames keeps payload-less variants (sury-compiled bare
  // `S.literal("Name")` strings) — the JSON envelope's `event` TAG still
  // carries the literal name, so the filter would otherwise drop them.
  let acceptedTags = Reventless.DcbTag.extractAllVariantNames(Delegate.eventSchema)

  // Lazily-computed partition-tag derivation for `PublishStateChangeSliceCommand*`.
  // Derived from the Delegate's command schema; throws if no `@partitionTag` /
  // `@compositePartitionTag` annotation exists (i.e. the Delegate is an Aggregate,
  // not a StateChangeSlice — in which case the user should use
  // `PublishAggregateCommand` instead).
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

  let compLog = (comp, msg) =>
    Effect.logInfo(`${Reventless.LogPrefix.fmtComp(~comp, ())}${msg}`)->Effect.runSync

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
      | Call(handler, directive) =>
        compLog(`Extension(${extensionPointName})`, "incoming Call directive")
        AbstractCall(() => handler(directive))
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
    // Pre-filter by TAG: sibling variants from the source log that the Delegate
    // did not declare are not this mapping's concern — skip silently with no
    // decode attempt.
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
        | Call(handler, directive) =>
          compLog(`Extension(${delegateName})`, "outgoing Call directive")
          AbstractCall(() => handler(directive))
        }
      )
    }
  }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
