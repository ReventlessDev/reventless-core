// Local-only intermediate type used by Plugin_Builder during construction.
// All fields use Pulumi.Output.t-wrapped component output types because they
// originate from freshly-built local components (not deserialized stack exports).
// Cross-stack consumers use ReventlessInterop.Plugin.resolvedOutputs instead.
type builderOutputs = {
  id: string,
  version: string,
  heartbeatInterval: int,
  eventCollector: EventCollector.outputs,
  extensionPoints: dict<ExtensionPoint.outputs>,
  extensions: dict<Extension.outputs>,
  aggregates: dict<Aggregate.outputs>,
  stateChangeSlices: dict<StateChangeSlice.outputs>,
  stateViewSlices: dict<StateViewSlice.outputs>,
  automationSlices: dict<AutomationSlice.outputs>,
  outboundTranslationSlices: dict<OutboundTranslationSlice.outputs>,
  inboundTranslationSlices: dict<InboundTranslationSlice.outputs>,
  readModels: dict<ReadModel.outputs>,
  tasks: dict<Task.outputs>,
  resolvers: array<ReventlessInfra.Adapter.resource>,
  heartbeat: Heartbeat.outputs,
  dcbEventLog: option<DcbEventLog.outputs>,
}

let getRemoteStorageResources = (pluginName, queryDbName) =>
  switch Util_StackRefs.get(pluginName)->Option.map(stackRef => {
    // Read both _interopMeta (for field-manifest validation) and "plugin" (the export).
    // Both are annotated as option<JSON.t> so Pulumi's untyped output unifies with sury's JSON.t.
    let metaOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("_interopMeta")
    let pluginOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("plugin")

    metaOutput->Pulumi.Output.flatMap(metaOpt =>
      pluginOutput->Pulumi.Output.apply(pluginOpt =>
        switch (metaOpt, pluginOpt) {
        | (Some(rawMeta), Some(rawPlugin)) =>
          switch ReventlessInterop.Query.parseMeta(rawMeta) {
          | Ok(meta) =>
            switch ReventlessInterop.Compat.validateAndProject(
              ~stackName=pluginName,
              ~meta,
              ~outputName="plugin",
              ~rawJson=rawPlugin,
              ~requiredFields=["readModels"],
              ~fromJson=json =>
                try Ok(json->S.parseOrThrow(ReventlessInterop.Plugin.resolvedOutputsSchema))
                catch {
                | exn =>
                  let msg =
                    exn
                    ->JsExn.fromException
                    ->Option.flatMap(JsExn.message)
                    ->Option.getOr("parse error")
                  Error(msg)
                },
            ) {
            | Ok(plugin) =>
              plugin.readModels
              ->Option.flatMap(readModels => readModels->Dict.get(queryDbName))
              ->Option.map(readModel =>
                readModel.queryDb.resources->Adapter.fromInteropResources
              )
              ->Option.getOr([])
            | Error(err) =>
              Console.log2(
                `Plugin_Builder.getRemoteStorageResources: compat error for ${pluginName}:`,
                err,
              )
              []
            }
          | Error(msg) =>
            Console.log2(
              `Plugin_Builder.getRemoteStorageResources: failed to parse _interopMeta for ${pluginName}:`,
              msg,
            )
            []
          }
        | _ => []
        }
      )
    )
  }) {
  | Some(resources) => resources
  | None =>
    Console.log(`Plugin_Builder.getRemoteStorageResources: Couldn't find Plugin ${pluginName}`)
    []->Pulumi.Output.make
  }

let getStorageResources = (allQueryDbs, pluginName, queryDbName) =>
  switch pluginName {
  | None => Util_QueryDb.getLocalStorageResources(allQueryDbs, queryDbName)->Pulumi.Output.make
  | Some(pluginName) => getRemoteStorageResources(pluginName, queryDbName)
  }

type jsonEventsHandler = Plugin_Callback.jsonEventsHandler
type jsonEventsHandlers = {
  outgoing?: jsonEventsHandler,
  incoming?: jsonEventsHandler,
}
let getIncomingJsonEventsHandler = jsonEventsHandlers => jsonEventsHandlers.incoming
let getOutgoingJsonEventsHandler = jsonEventsHandlers => jsonEventsHandlers.outgoing

let serviceNameToJsonEventsHandlers: (
  array<'o>,
  'o => array<string>,
  array<jsonEventsHandlers>,
  jsonEventsHandlers => option<jsonEventsHandler>,
) => dict<array<jsonEventsHandler>> = (outputs, getServiceNames, handlers, getEventHandler) => {
  let dict = Dict.make()
  Array.zip(outputs, handlers)->Array.forEach(((outputs, jsonEventsHandlers)) => {
    jsonEventsHandlers
    ->getEventHandler
    ->Option.forEach(jsonEventsHandler =>
      outputs
      ->getServiceNames
      ->Array.forEach(
        serviceName =>
          switch dict->Dict.get(serviceName) {
          | Some(jsonEventsHandlers) =>
            Dict.set(dict, serviceName, jsonEventsHandlers->Array.concat([jsonEventsHandler]))
          | None => Dict.set(dict, serviceName, [jsonEventsHandler])
          },
      )
    )
  })
  dict
}

include Builder_Helpers

let createExtensions = (
  extensions,
  ~publishToPluginExtensionPoint,
  ~publishToAggregates,
  ~publishToReadModels,
  ~queryEngine,
  ~opts,
) =>
  extensions
  ->Array.map((module(SpecificExtension: ReventlessInfra.Extension.T)) => {
    let extension = SpecificExtension.make(
      ~publishToPluginExtensionPoint,
      ~publishToAggregates,
      ~readModelNamesForSourceName,
      ~publishToReadModels,
      ~queryEngine,
      ~opts=Some(opts),
    )
    // operations() returns abstract type from ReventlessInfra.Extension.T;
    // coerce to the concrete Extension.operations (always identical at runtime).
    let ops: Pulumi.Output.t<Extension.operations> =
      SpecificExtension.operations(extension)->Obj.magic
    (
      SpecificExtension.outputs(extension),
      ops->Pulumi.Output.apply(({outgoingJsonEventsHandler, incomingJsonEventsHandler}) => {
        incoming: incomingJsonEventsHandler,
        outgoing: outgoingJsonEventsHandler,
      }),
    )
  })
  ->Array.unzip

let extractExtensionPointDefinitions = (extensionPointsOutputs: array<ExtensionPoint.outputs>) =>
  extensionPointsOutputs
  ->Array.map(extensionPointOutputs =>
    (
      extensionPointOutputs.commandTopic->Pulumi.Output.flatMap(({resources}) =>
        switch resources->Array.get(0) {
        | Some(r) => r.id
        | None => Pulumi.Output.make("")
        }
      ),
      extensionPointOutputs.eventTopic->Pulumi.Output.flatMap(({resources}) =>
        switch resources->Array.get(0) {
        | Some(r) => r.id
        | None => Pulumi.Output.make("")
        }
      ),
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((commandTopicChannelId, eventTopicPublisherId)) => {
      Reventless.Plugin.name: extensionPointOutputs.name,
      commandTopic: commandTopicChannelId,
      eventTopic: eventTopicPublisherId,
    })
  )
  ->Pulumi.Output.all

let extractExtensionDefinitions = (extensionsOutputs: array<Extension.outputs>) =>
  extensionsOutputs->Array.map(extensionOutputs => {
    Reventless.Plugin.name: extensionOutputs.name,
    extensionPointName: extensionOutputs.extensionPointName,
  })

let createConnectPluginExtension = (
  ~pluginDefinition,
  ~extensionPointsOutputs,
  ~extensionsOutputs,
  ~publishToPluginExtensionPoint,
  ~publishToAggregates,
  ~readModelNamesForSourceName,
  ~publishToReadModels,
  ~queryEngine,
  ~runtimeOps,
  ~resourceNaming,
  ~opts,
) =>
  (
    extensionPointsOutputs
    ->Array.map(ExtensionPoint.toResolvedOutputs)
    ->Pulumi.Output.all,
    pluginDefinition,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((extensionPointsOutputs, pluginDefinition)) => {
    module ConnectPluginExtension = PluginConnectExtension_Builder.Make({
      let pluginDefinition = pluginDefinition
      let extensionPointsOutputs = extensionPointsOutputs
      let extensionsOutputs = extensionsOutputs
      let runtimeOps = runtimeOps
      let resourceNaming = resourceNaming
    })
    let connectPluginExtension = ConnectPluginExtension.make(
      ~publishToPluginExtensionPoint,
      ~publishToAggregates,
      ~readModelNamesForSourceName,
      ~publishToReadModels,
      ~queryEngine,
      ~opts=Some(opts),
    )
    let connectPluginExtensionOutputs = connectPluginExtension->Component.outputs
    let connectPluginExtensionIncomingEventHandler =
      connectPluginExtension
      ->Component.operations
      ->Pulumi.Output.apply(({incomingJsonEventsHandler}) => incomingJsonEventsHandler)

    (connectPluginExtensionOutputs, connectPluginExtensionIncomingEventHandler)
  })
  ->Pulumi.Output.unzip

let tasksOutputs = ref([])

let createTasks = (
  tasks,
  ~aggregatesOutputs,
  ~scheduler,
  ~publishToAggregates,
  ~queryEngine,
  ~resourceNaming,
  ~opts,
) => {
  tasksOutputs :=
    tasks->Array.map((module(SpecificTask: ReventlessInfra.Task.T)) =>
      SpecificTask.outputs(SpecificTask.make(
        ~queryBucketName=(~taskName, ~bucketName="Bucket") =>
          ResourceQueryRuntime.bucketNameOfTaskExn(tasksOutputs.contents, ~taskName, ~bucketName),
        ~scheduler,
        ~publishToAggregates,
        ~queryEngine,
        ~resourceNaming,
        ~allAggregates=aggregatesOutputs,
        ~opts=Some(opts),
      ))
    )
  tasksOutputs.contents
}

module MakeEventCollectorHelper = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  PluginRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
) => {
  module PluginEventCollector = EventCollector_Builder.Make(
    RuntimeEnvironment,
    EventCollectorChannel,
  )
  let make = (~name, ~eventTopics, ~opts) => {
    let eventCollector = PluginEventCollector.make(~name, ~eventTopics, ~opts)
    let eventCollectorOutputs = eventCollector->Component.outputs
    let eventCollectorUrn = switch eventCollectorOutputs.resources->Array.get(0) {
    | Some(r) => r.urn
    | None => Pulumi.Output.make("")
    }

    (eventCollector, eventCollectorOutputs, eventCollectorUrn)
  }

  // Unified connect — handles both with-admin and without-admin cases.
  // When ~pluginExtensionPointUnwrapped is provided, admin extension point
  // resources and ConnectPluginExtension handlers are wired.  Otherwise falls
  // back to a simplified path (no admin extension point resources, empty
  // incoming connect extension handlers).
  let connect = (
    ~eventCollector: EventCollector.component,
    ~eventTopics: EventTopic.allOutputs,
    ~extensionPointsOutputs: array<ExtensionPoint.outputs>,
    ~extensionsOutputs: array<Extension.outputs>,
    ~pluginExtensionPointUnwrapped: option<ReventlessInterop.ExtensionPoint.resolvedOutputs>=?,
    ~pluginDefinition,
    ~connectPluginExtensionIncomingEventHandler: option<Pulumi.Output.t<Pulumi.Output.t<Plugin_Callback.jsonEventsHandler>>>=?,
    ~extensionsHandlers,
    ~extensionPointsHandlers,
    ~connectPluginExtensionOutputs: option<Pulumi.Output.t<Extension.outputs>>=?,
  ) => {
    let resources =
      extensionPointsOutputs
      ->Array.map(extensionPoint => extensionPoint.eventTopic)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(eventTopics => {
        let base =
          eventTopics
          ->Array.map(eventTopic => eventTopic.resources)
          ->Array.flat
        switch pluginExtensionPointUnwrapped {
        | Some(unwrapped) =>
          base->Array.concat(unwrapped.commandTopic.resources->Adapter.fromInteropResources)
        | None => base
        }
      })

    // Resolve ConnectPluginExtension data (or provide defaults for no-Core path)
    let connectExtData =
      switch (connectPluginExtensionIncomingEventHandler, connectPluginExtensionOutputs) {
      | (Some(handler), Some(outputs)) =>
        (handler->Pulumi.Output.unwrap, outputs)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((h, o)) => Some((h, o)))
      | _ => Pulumi.Output.make(None)
      }

    (
      pluginDefinition,
      connectExtData,
      extensionsHandlers->Pulumi.Output.all,
      extensionPointsHandlers->Pulumi.Output.all,
      resources,
    )
    ->Pulumi.Output.all5
    ->Pulumi.Output.apply(((
      pluginDefinition,
      connectExtData,
      extensionsHandlers,
      extensionPointsHandlers,
      resources,
    )) => {
      let incomingConnectExtensionEventHandlers = switch connectExtData {
      | Some((handler, outputs)) =>
        serviceNameToJsonEventsHandlers(
          [outputs],
          outputs => [outputs.extensionPointName],
          [{incoming: handler}],
          getIncomingJsonEventsHandler,
        )
      | None => Dict.make()
      }
      module Callback = Plugin_Callback.Make({
        let pluginDefinition = pluginDefinition
        let outgoingExtensionPointEventHandlers = serviceNameToJsonEventsHandlers(
          extensionPointsOutputs,
          outputs => outputs.aggregateNames,
          extensionPointsHandlers->Array.map(extensionPointsHandler => {
            outgoing: extensionPointsHandler,
          }),
          getOutgoingJsonEventsHandler,
        )
        let incomingConnectExtensionEventHandlers = incomingConnectExtensionEventHandlers
        let outgoingExtensionEventHandlers = serviceNameToJsonEventsHandlers(
          extensionsOutputs,
          outputs => outputs.aggregateNames,
          extensionsHandlers,
          getOutgoingJsonEventsHandler,
        )
        let incomingExtensionEventHandlers = serviceNameToJsonEventsHandlers(
          extensionsOutputs,
          outputs => [outputs.extensionPointName],
          extensionsHandlers,
          getIncomingJsonEventsHandler,
        )
      })
      let handler = PluginEventCollector.makeHandler(
        ~eventCollector,
        ~jsonEventsHandler=Callback.handleJsonEvents,
      )
      eventCollector->PluginRuntimeBuilder.forPluginEventCollector(
        ~handler,
        ~eventTopics,
        ~resources,
      )

      let _ = switch (eventCollector->Component.outputs).resources->Array.get(0) {
      | Some(r) => r.urn->Pulumi.Output.apply(urn => pluginDefinition.eventCollector = urn)
      | None => Pulumi.Output.make()
      }
    })
  }
}


// ---------------------------------------------------------------------------
// Local admin extension points — set by Platform_Admin.construct() during
// admin construction.  When set, Plugin_Builder uses these to wire the admin
// connection path locally instead of via Interstack.coreStackReference.
// This eliminates the need for connectWithoutCore in platforms like in-memory
// where admin and plugins run in the same process.
// ---------------------------------------------------------------------------
let localAdminExtensionPoints: ref<option<Pulumi.Output.t<dict<ExtensionPoint.outputs>>>> = ref(None)

// ---------------------------------------------------------------------------
// Unified mutation resolver hooks — set by in-memory platform before plugins
// are built.  Used by both Plugin_Builder (aggregates) and Dcb_Builder
// (StateChangeSlices) to register GraphQL mutation SDL + resolver stubs.
// Phase 1 (mutationResolverHook): called synchronously to register SDL + stub.
// Phase 2 (mutationBindHook): called inside Output.apply to bind generateCommand.
// No-op when unset (AWS/other platforms).
// ---------------------------------------------------------------------------
type mutationKind = Aggregate | Dcb

let mutationResolverHook: ref<
  option<(~kind: mutationKind, ~fields: array<string>, ~commandSchema: S.t<unknown>) => unit>,
> = ref(None)

let mutationBindHook: ref<
  option<(~field: string, ~generateCommand: CommandGenerator.commandGenerator) => unit>,
> = ref(None)

// ---------------------------------------------------------------------------
// InboundTranslationSlice mutation resolver hooks — set by in-memory platform
// before plugins are built.
// Phase 1 (registerHook): called synchronously to register SDL + resolver stub.
// Phase 2 (bindReceiveHook): called inside Output.apply to bind `receive`.
// ---------------------------------------------------------------------------
let inboundMutationResolverHook: ref<
  option<(~fieldName: string, ~externalInputSchema: S.t<unknown>) => unit>,
> = ref(None)

let inboundMutationBindReceiveHook: ref<
  option<(~fieldName: string, ~receive: JSON.t => promise<result<string, string>>) => unit>,
> = ref(None)

// ---------------------------------------------------------------------------
// InboundTranslationSlice AppSync resolver hook — set by AWS platform before
// plugins are built.  Plugin_Builder.construct() calls this from the DCB
// connect function to create AppSync DataSource + Resolvers for each
// InboundTranslationSlice, pointing to the shared DCB CommandTopic Lambda.
// No-op when unset (in-memory/other platforms).
// ---------------------------------------------------------------------------
type inboundAppSyncResolverParams = {
  runtime: Runtime.environment<unknown>,
  fieldNames: array<string>,
  externalInputSchemas: array<S.t<unknown>>,
  opts: Pulumi.ComponentResource.options,
}
let inboundAppSyncResolverHook: ref<option<inboundAppSyncResolverParams => unit>> = ref(None)

// ---------------------------------------------------------------------------
// DCB StateChangeSlice AppSync resolver hook — set by AWS platform before
// plugins are built.  Dcb_Builder.construct() calls this from the DCB connect
// function to create AppSync DataSource + Resolvers for each StateChangeSlice,
// pointing to the shared DCB CommandTopic Lambda.
// No-op when unset (in-memory/other platforms).
// ---------------------------------------------------------------------------
type dcbAppSyncResolverParams = {
  runtime: Runtime.environment<unknown>,
  fieldNames: array<string>,
  tags: array<string>,
  opts: Pulumi.ComponentResource.options,
}
let dcbAppSyncResolverHook: ref<option<dcbAppSyncResolverParams => unit>> = ref(None)

// (aggregateMutationResolverHook removed — replaced by unified mutationResolverHook above)

// ---------------------------------------------------------------------------
// Schema type registration hook — set by in-memory platform before plugins are
// built.  Plugin_Builder.construct() calls this after generating the fragment
// to register GraphQL type definitions.  No-op when unset (AWS/other platforms).
// ---------------------------------------------------------------------------
let schemaTypeRegistrationHook: ref<option<array<string> => unit>> = ref(None)

// ---------------------------------------------------------------------------
// Query field names registry — populated by Plugin_Builder during construct()
// to map QueryDb component names → plugin-prefixed GraphQL query field names.
// Read by QueryDbResolvers_GraphQL.make() to align resolver SDL with fragment SDL.
// ---------------------------------------------------------------------------
let queryFieldNamesRegistry: ref<dict<Api_Naming.queryNames>> = ref(Dict.make())

// ---------------------------------------------------------------------------
// Aggregate mutation field names registry — populated by Plugin_Builder during
// construct() to map aggregate Spec.name → plugin-prefixed mutation field names.
// Read by CommandGenerator_Builder.connect() to override the empty
// Behavior.resolverConfig.fields with the correct plugin-prefixed names.
// ---------------------------------------------------------------------------
let aggregateMutationFieldsRegistry: ref<dict<array<string>>> = ref(Dict.make())

// ---------------------------------------------------------------------------
// MCP schema registration hook — set by in-memory platform before plugins are
// built.  Plugin_Builder.construct() calls this after generating entries to
// register MCP tools and resources.  No-op when unset (AWS/other platforms).
// ---------------------------------------------------------------------------
type mcpRegistrationParams = {
  pluginName: string,
  mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
}
let mcpSchemaRegistrationHook: ref<option<mcpRegistrationParams => unit>> = ref(None)

// ---------------------------------------------------------------------------
// Pre-resolvers schema push hook — set by AWS platform so that plugin stacks
// push their schema fragment to AppSync BEFORE creating QueryDb resolvers.
// The hook returns Output.t<unit> so callers can chain resolver creation after it.
// No-op when unset (in-memory/other platforms).
// ---------------------------------------------------------------------------
let preResolversSchemaHook: ref<
  option<Reventless.Plugin.apiSchemaFragment => Pulumi.Output.t<unit>>,
> = ref(None)

// ---------------------------------------------------------------------------
// Interop metadata — computed from builderOutputs at deploy time and stored so
// that the plugin's entry-point module can export it as `_interopMeta`.
// ---------------------------------------------------------------------------

// Module-level ref; follows the same mutable-state pattern as `tasksOutputs`
// above.  Set by Plugin_Builder during construct(); read by user entry-point
// code via `getInteropMeta()`.
let interopMetaOutput: ref<option<Pulumi.Output.t<ReventlessInterop.ExportMeta.t>>> = ref(None)

// Derive a field-name union across all tasks (field names present in at least
// one task's serialized resolvedOutputs).  Optional fields only appear in the
// union when they are Some in the source Task.outputs record.
let taskFieldUnion = (tasks: dict<Task.outputs>): array<string> => {
  module SSet = Belt.Set.String
  tasks
  ->Dict.valuesToArray
  ->Array.reduce(SSet.empty, (acc, taskOutput) => {
    // Convert Task.outputs → Task.resolvedOutputs using placeholders for nested
    // Pulumi.Output.t values — we only need presence, not actual string content.
    // ReScript optional fields must be set to the inner type (not option<_>) in
    // record literals, so we use a switch to conditionally include them.
    let resolved: ReventlessInterop.Task.resolvedOutputs =
      switch (taskOutput.bucketNames, taskOutput.sideEffectSources) {
      | (None, None) => {name: taskOutput.name}
      | (Some(_), None) => {name: taskOutput.name, bucketNames: Dict.make()}
      | (None, Some(src)) => {name: taskOutput.name, sideEffectSources: src}
      | (Some(_), Some(src)) => {
          name: taskOutput.name,
          bucketNames: Dict.make(),
          sideEffectSources: src,
        }
      }
    ReventlessInterop.ExportMeta.fieldNamesOf(resolved, ReventlessInterop.Task.resolvedOutputsSchema)
    ->Array.reduce(acc, SSet.add)
  })
  ->SSet.toArray
}

// Build an ExportMeta.t from builderOutputs.  Called inside a Pulumi.Output.apply
// so all top-level Output.t wrappers in builderOutputs are already resolved.
// Nested Output.t values (e.g. inside Task.bucketNames dict values) are still
// pending — we use placeholder detection (Some vs None) rather than unwrapping.
let toInteropMeta = (outputs: builderOutputs): ReventlessInterop.ExportMeta.t => {
  // Include optional fields only when the corresponding dict is non-empty,
  // so old publishers with empty dicts produce a conservative manifest.
  // ReScript optional fields cannot be set via option<_> in record literals.
  let hasReadModels = outputs.readModels->Dict.toArray->Array.length > 0
  let hasExtensionPoints = outputs.extensionPoints->Dict.toArray->Array.length > 0
  let pluginResolved: ReventlessInterop.Plugin.resolvedOutputs =
    switch (hasReadModels, hasExtensionPoints) {
    | (false, false) => {id: outputs.id, version: outputs.version}
    | (true, false) => {id: outputs.id, version: outputs.version, readModels: Dict.make()}
    | (false, true) => {id: outputs.id, version: outputs.version, extensionPoints: Dict.make()}
    | (true, true) => {
        id: outputs.id,
        version: outputs.version,
        readModels: Dict.make(),
        extensionPoints: Dict.make(),
      }
    }

  // EventMapper field manifest uses minimum required fields (counter presence
  // cannot be checked without resolving inner Output.t — improved in later phase).
  let eventMapperMinimal: ReventlessInterop.EventMapper.resolvedOutputs = {
    name: "",
    eventCollector: {name: "", resources: []},
  }

  {
    version: ReventlessInterop.ExportMeta.version,
    fields: Dict.fromArray([
      ("tasks", taskFieldUnion(outputs.tasks)),
      (
        "eventMappers",
        ReventlessInterop.ExportMeta.fieldNamesOf(
          eventMapperMinimal,
          ReventlessInterop.EventMapper.resolvedOutputsSchema,
        ),
      ),
      (
        "plugin",
        ReventlessInterop.ExportMeta.fieldNamesOf(
          pluginResolved,
          ReventlessInterop.Plugin.resolvedOutputsSchema,
        ),
      ),
    ]),
  }
}

// Returns the computed interop meta Output.  Call this from the plugin's entry-
// point module and export the result as `let _interopMeta = getInteropMeta()`.
let getInteropMeta = () =>
  interopMetaOutput.contents->Option.getOrThrow(
    ~message="getInteropMeta() called before Plugin_Builder.construct()",
  )
