let log = Logger.fromEnv()

// Wrapper to safely store Pulumi Output values as option fields.
// Pulumi Outputs are JS Proxies; wrapping them directly in Some() triggers
// the BS_PRIVATE_NESTED_SOME_NONE sentinel bug.  Storing as {val: x} avoids
// this because the plain record has no BS_PRIVATE_NESTED_SOME_NONE property.
type hookedValue<'a> = {val: 'a}

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
    // Read the "readModels" top-level export directly (no longer nested under "plugin").
    let readModelsOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("readModels")

    readModelsOutput->Pulumi.Output.apply(readModelsOpt =>
      switch readModelsOpt {
      | Some(rawReadModels) =>
        switch rawReadModels->JSON.Decode.object {
        | Some(dict) =>
          switch dict->Dict.get(queryDbName) {
          | Some(rawReadModel) =>
            try {
              let readModel =
                rawReadModel->S.parseOrThrow(ReventlessInterop.ReadModel.resolvedOutputsSchema)
              readModel.queryDb.resources->Adapter.fromInteropResources
            } catch {
            | exn =>
              let msg =
                exn
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("parse error")
              log.error(
                ~comp="Plugin_Helpers",
                `getRemoteStorageResources: failed to parse readModel ${queryDbName} from ${pluginName}: ${msg}`,
              )
              []
            }
          | None => []
          }
        | None => []
        }
      | None => []
      }
    )
  }) {
  | Some(resources) => resources
  | None =>
    let known = Util_StackRefs.stackRefs->Dict.keysToArray->Array.join(",")
    log.error(
      ~comp="Plugin_Helpers",
      `getRemoteStorageResources: plugin ${pluginName} not found (check platform.stack config) known=[${known}]`,
    )
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

module ApiNoApi = ApiNoApiHelpers

let isNoApi = ApiNoApi.isNoApi
let getExcludedVariants = ApiNoApi.getExcludedVariants
let filterNoApiVariants = ApiNoApi.filterNoApiVariants

let createExtensions = (
  extensions: array<module(ReventlessInfra.Extension.Blueprint)>,
  ~pluginName,
  ~publishToPluginExtensionPoint,
  ~publishToAggregates,
  ~publishToReadModels,
  ~queryEngine,
  ~opts,
) => {
  // Group blueprints by extension point name for auto-merge.
  let groups: dict<array<module(ReventlessInfra.Extension.Blueprint)>> = Dict.make()
  extensions->Array.forEach(bp => {
    let module(BP: ReventlessInfra.Extension.Blueprint) = bp
    let epName = BP.Spec.name
    switch groups->Dict.get(epName) {
    | Some(existing) => existing->Array.push(bp)
    | None => groups->Dict.set(epName, [bp])
    }
  })

  // For each EP group: merge mappings, build Extension component.
  groups
  ->Dict.toArray
  ->Array.map(((_epName, blueprints)) => {
    // Use the first blueprint's Spec as the canonical type.
    let module(First: ReventlessInfra.Extension.Blueprint) = blueprints->Array.getUnsafe(0)

    // Merge all mappings arrays. Blueprints for the same EP have the same Spec
    // at runtime — use Obj.magic to unify the existential Mapping types.
    let allMappings: array<module(First.Mapping)> =
      blueprints->Array.flatMap(bp => {
        let module(BP: ReventlessInfra.Extension.Blueprint) = bp
        (BP.mappings: array<module(BP.Mapping)>)->Obj.magic
      })

    // Build the Extension component with pluginName as the extension name.
    module Spec = First.Spec
    module Mappings: Extension.Mappings with module Spec := Spec = {
      module type Mapping = ReventlessInfra.ExtensionMapping.T
        with module ExtensionPoint := Spec
      let name = pluginName
      let moduleUrl = First.moduleUrl
      let mappings: array<module(Mapping)> = allMappings->Obj.magic
    }
    module ExtensionMaker = Extension_Builder.Make(Spec, Mappings)

    let extension = ExtensionMaker.make(
      ~publishToPluginExtensionPoint,
      ~publishToAggregates,
      ~readModelNamesForSourceName,
      ~publishToReadModels,
      ~queryEngine,
      ~opts=Some(opts),
    )
    let ops: Pulumi.Output.t<Extension.operations> =
      ExtensionMaker.operations(extension)->Obj.magic
    (
      ExtensionMaker.outputs(extension),
      ops->Pulumi.Output.apply(({outgoingJsonEventsHandler, incomingJsonEventsHandler}) => {
        incoming: incomingJsonEventsHandler,
        outgoing: outgoingJsonEventsHandler,
      }),
    )
  })
  ->Array.unzip
}

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
// Shared schema type and plugin-built hook — re-exported from Plugin_Callbacks
// (runtime-safe, no Pulumi imports) for backward compatibility.
// ---------------------------------------------------------------------------
include Plugin_BuiltHook

// ---------------------------------------------------------------------------
// Plugin-deployed hook — fires inside Output.apply after all component
// resources have resolved, providing fully resolved resource data.
// ---------------------------------------------------------------------------
type pluginDeployedSubComponent = {
  role: string,
  resources: array<ReventlessInterop.Resource.t>,
}

type pluginDeployedComponent = {
  name: string,
  kind: string,
  schema: pluginDeployedSchema,
  resources: array<ReventlessInterop.Resource.t>,
  subComponents: array<pluginDeployedSubComponent>,
}

type extensionWiring = {
  extensionName: string,
  extensionPointName: string,
  providerPlugin: string,
  providerVersion: string,
  subscriberPlugin: string,
  subscriberVersion: string,
}

type pluginDeployedInfo = {
  name: string,
  version: string,
  environment: string,
  stackName: string,
  deployedAt: string,
  actor: string,
  deploymentId: string,
  kind?: pluginKind,
  displayName?: string,
  vendor?: string,
  architectureType?: architectureType,
  components: array<pluginDeployedComponent>,
  extensionWirings: array<extensionWiring>,
}

let onPluginDeployedHook: ref<option<pluginDeployedInfo => promise<unit>>> = ref(None)

let registerOnPluginDeployed = (hook: pluginDeployedInfo => promise<unit>) => {
  onPluginDeployedHook.contents = Some(hook)
}

let clearOnPluginDeployed = () => {
  onPluginDeployedHook.contents = None
}

// ---------------------------------------------------------------------------
// Platform-deployed hook — fires after deployPlatform / makePlatform
// completes, providing platform-level metadata with resolved values.
// ---------------------------------------------------------------------------
type platformDeployedInfo = {
  name: string,
  environment: string,
  region: string,
  // Domain API — handles application mutations from plugin stacks.
  domainApiEndpoint: string,
  domainApiRoleArn: string,
  // Platform API — handles Platform_Sync* and admin mutations.
  // Equals domainApiEndpoint/domainApiRoleArn in unified (non-split) mode.
  platformApiEndpoint: string,
  platformApiRoleArn: string,
  adminResources: array<ReventlessInterop.Resource.t>,
}

let onPlatformDeployedHook: ref<option<platformDeployedInfo => unit>> = ref(None)

let registerOnPlatformDeployed = (hook: platformDeployedInfo => unit) => {
  onPlatformDeployedHook.contents = Some(hook)
}

let clearOnPlatformDeployed = () => {
  onPlatformDeployedHook.contents = None
}

// Resolver error hook has moved to Plugin_ResolverError to keep it on the
// runtime-safe import chain (CommandGenerator_Callback runs in Lambda; this
// module pulls in Pulumi for deploy-time helpers).

// ---------------------------------------------------------------------------
// Shared parameter types for hooks that carry structured data.
// ---------------------------------------------------------------------------
type mutationKind = Aggregate | Dcb

type inboundAppSyncResolverParams = {
  runtime: Runtime.environment<unknown>,
  fieldNames: array<string>,
  externalInputSchemas: array<S.t<unknown>>,
  opts: Pulumi.ComponentResource.options,
}

type dcbAppSyncResolverParams = {
  runtime: Runtime.environment<unknown>,
  fieldNames: array<string>,
  tags: array<string>,
  opts: Pulumi.ComponentResource.options,
}

// ---------------------------------------------------------------------------
// Query field names registry — populated by Plugin_Builder during construct()
// to map QueryDb component names → plugin-prefixed GraphQL query field names.
// Read by QueryDbResolvers_GraphQL.make() to align resolver SDL with fragment SDL.
// ---------------------------------------------------------------------------
let queryFieldNamesRegistry: dict<Api_Naming.queryNames> = Dict.make()

// ---------------------------------------------------------------------------
// Aggregate mutation field names registry — populated by Plugin_Builder during
// construct() to map aggregate Spec.name → plugin-prefixed mutation field names.
// Read by CommandGenerator_Builder.connect() to provide plugin-prefixed mutation field names.
// ---------------------------------------------------------------------------
let aggregateMutationFieldsRegistry: dict<array<string>> = Dict.make()

// ---------------------------------------------------------------------------
// MCP schema registration params type — shared by platformHooks and callers.
// ---------------------------------------------------------------------------
type mcpRegistrationParams = {
  pluginName: string,
  mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
  /** Subscription SDL field strings from the plugin fragment (Sources A, B, C).
      Used by the in-memory platform to register yoga WebSocket subscription resolvers. */
  subscriptionFields: array<string>,
}

// Subscription infrastructure hook params — fired after allQueryDbs and allEventTopics
// are assembled inside builderOutputs.  Lets the AWS platform wire StateTopic and
// EventLogSubscription Lambdas without touching reventless-core.
type subscriptionInfraParams = {
  allQueryDbs: ReventlessInfra.QueryDb.allOutputs,
  allEventTopics: dict<ReventlessInfra.EventTopic.outputs>,
  eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
  opts: Pulumi.ComponentResource.options,
}

// ---------------------------------------------------------------------------
// platformHooks — platform callbacks and coordination state passed to builder
// functors as a record.
//
// Optional fields (field?): callbacks set at record creation; absent = None.
// Required ref field: adminExtensionPoints — a mutable cell set by makePlatform
// after Admin.construct() returns, read by Plugin_Builder to wire the local
// admin connection path (in-memory). Initialized to an empty dict output;
// AWS platforms leave it empty and fall back to Interstack instead.
//
// `noHooks` is the "no callbacks" default, with adminExtensionPoints starting
// as an empty dict output.
// ---------------------------------------------------------------------------
type platformHooks = {
  // ── In-memory GraphQL mutation registration ────────────────────────────
  // Phase 1: register SDL + resolver stub synchronously.
  mutationResolverHook?: (~kind: mutationKind, ~fields: array<string>, ~commandSchema: S.t<unknown>) => unit,
  // Phase 2: bind generateCommand inside Output.apply.
  mutationBindHook?: (~field: string, ~generateCommand: CommandGenerator.commandGenerator) => unit,
  // InboundTranslationSlice — phase 1: register SDL + stub.
  inboundMutationResolverHook?: (~fieldName: string, ~externalInputSchema: S.t<unknown>) => unit,
  // InboundTranslationSlice — phase 2: bind receive.
  inboundMutationBindReceiveHook?: (~fieldName: string, ~receive: JSON.t => promise<result<array<string>, string>>) => unit,
  // GraphQL type definitions.
  schemaTypeRegistrationHook?: array<string> => unit,
  // Subscription infrastructure (AWS): wire StateTopic + EventLogSubscription Lambdas.
  // Fired inside builderOutputs after allQueryDbs and allEventTopics are assembled.
  subscriptionInfraHook?: subscriptionInfraParams => unit,
  // MCP tools and resources.
  mcpSchemaRegistrationHook?: mcpRegistrationParams => unit,
  // ── AppSync resolver creation (AWS) ───────────────────────────────────
  preResolversSchemaHook?: (~name: string, Reventless.Plugin.apiSchemaFragment) => Pulumi.Output.t<unit>,
  inboundAppSyncResolverHook?: inboundAppSyncResolverParams => unit,
  dcbAppSyncResolverHook?: dcbAppSyncResolverParams => unit,
  // ── Deployment lifecycle (AWS) ─────────────────────────────────────────
  onDcbEventLogCreated?: unknown => unit,
  onDcbCommandTopicCreated?: unknown => unit,
  onDcbSlicesCreated?: unknown => unit,
  onHeartbeatEpChannelAvailable?: unknown => unit,
  // ── Admin → Plugin coordination ────────────────────────────────────────
  // Set by makePlatform after Admin.construct(); read by Plugin_Builder to
  // wire the local admin connection path (in-memory).  Starts as an empty
  // dict; AWS platforms leave it empty and use Interstack instead.
  adminExtensionPoints: ref<Pulumi.Output.t<dict<ExtensionPoint.outputs>>>,
  // ── Platform context (populated by makePlatform/deployPlugin) ──────────
  // Read by Plugin_Builder.make so app plugins don't need to pass these.
  // api/apiRole stored as hookedValue<unknown> to avoid Pulumi Output Proxy
  // corrupting ReScript option boxing (BS_PRIVATE_NESTED_SOME_NONE sentinel).
  // Cast back via Obj.magic in Plugin_Builder where concrete types are known.
  scheduler: ref<option<Pulumi.Output.t<Scheduler.operations>>>,
  api: ref<option<hookedValue<unknown>>>,
  apiRole: ref<option<hookedValue<unknown>>>,
  // Current deploy target, set by deployPlugin before plugin.make() is called.
  // "Domain" (default) → resolvers/schema go to the DomainApi.
  // "Platform" → resolvers/schema go to the PlatformApi.
  // Plugin_Builder captures this synchronously when constructing pluginDefinition
  // to avoid the async-reset race (deployPlugin resets to "Domain" after make()).
  deployTarget: ref<string>,
}

// Default hooks — no callbacks, empty platform context.
let noHooks: platformHooks = {
  adminExtensionPoints: ref(Pulumi.Output.make(Dict.make())),
  scheduler: ref(None),
  api: ref(None),
  apiRole: ref(None),
  deployTarget: ref("Domain"),
}

// Functor parameter wrapper for platformHooks.
module type HooksConfig = {
  let hooks: platformHooks
}

// Pre-built HooksConfig with no hooks — use for builders that need no callbacks
// (e.g. AWS aggregate builders that route via AggregateRuntimeBuilder instead).
module NoopHooksConfig: HooksConfig = {
  let hooks = noHooks
}

// ---------------------------------------------------------------------------
// Interop metadata — computed from builderOutputs at deploy time and stored so
// that the plugin's entry-point module can export it as `_interopMeta`.
// ---------------------------------------------------------------------------

// Module-level ref; follows the same mutable-state pattern as `tasksOutputs`
// above.  Set by Plugin_Builder during construct(); read by user entry-point
// code via `getInteropMeta()`.
// IMPORTANT: Do NOT use option<Pulumi.Output.t<_>> here.  Pulumi.Output.t is a
// JavaScript Proxy.  ReScript's Caml_option.some() checks for BS_PRIVATE_NESTED_SOME_NONE
// on the value — the Proxy intercepts that property access and returns a truthy value,
// causing some() to produce the sentinel object {BS_PRIVATE_NESTED_SOME_NONE: 0}
// instead of wrapping the actual Output.  Use a raw JS null ref to avoid option wrapping.
let interopMetaOutput: ref<Pulumi.Output.t<JSON.t>> = ref(%raw(`null`))

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
    ]),
  }
}

// Returns the computed interop meta Output.  Call this from the plugin's entry-
// point module and export the result as `let _interopMeta = getInteropMeta()`.
let getInteropMeta = (): Pulumi.Output.t<JSON.t> => {
  let v = interopMetaOutput.contents
  // Use raw null check to avoid option wrapping of the Proxy value.
  if %raw(`v === null`) {
    JsError.throwWithMessage("getInteropMeta() called before Plugin_Builder.construct()")
  } else {
    v
  }
}

// ---------------------------------------------------------------------------
// Stack metadata export — environment, region, timestamp, actor, git SHA.
// Called from both exportPluginOutputs and exportPlatformOutputs.
// ---------------------------------------------------------------------------
@val external processEnv: dict<string> = "process.env"

let exportDeploymentMetadata = () => {
  let metadata =
    [
      ("environment", Pulumi.Pulumi.getStackName()),
      ("region", Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")->Option.getOr("unknown")),
      ("timestamp", Date.make()->Date.toISOString),
      ("gitSha", processEnv->Dict.get("GITHUB_SHA")->Option.getOr("unknown")),
      ("actor", processEnv->Dict.get("GITHUB_ACTOR")->Option.getOr("unknown")),
    ]
    ->Dict.fromArray
  Pulumi.Pulumi.export(
    "deploymentMetadata",
    metadata->Dict.mapValues(JSON.Encode.string)->JSON.Encode.object->Pulumi.Output.make,
  )
}

// ---------------------------------------------------------------------------
// Serialize individual component output dicts as top-level Pulumi stack exports.
// Each component type gets its own export key (e.g. "aggregates", "readModels").
// ---------------------------------------------------------------------------

// Serialize a plain dict of component outputs to JSON. Unlike serializeDictExport,
// this does NOT wrap the dict in Pulumi.Output.make (which deeply resolves nested
// Outputs and breaks toResolvedOutputs).
let serializePlainDictExport = (
  dict: dict<'outputs>,
  toResolved: 'outputs => Pulumi.Output.t<'resolved>,
  schema: S.t<'resolved>,
): Pulumi.Output.t<JSON.t> =>
  dict
  ->Dict.toArray
  ->Array.map(((name, outputs)) =>
    outputs
    ->toResolved
    ->Pulumi.Output.apply(resolved => (
      name,
      resolved->S.reverseConvertToJsonOrThrow(schema),
    ))
  )
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray->JSON.Encode.object)

let serializeDictExport = (
  dictOutput: Pulumi.Output.t<dict<'outputs>>,
  toResolved: 'outputs => Pulumi.Output.t<'resolved>,
  schema: S.t<'resolved>,
): Pulumi.Output.t<JSON.t> =>
  dictOutput->Pulumi.Output.flatMap(dict =>
    dict
    ->Dict.toArray
    ->Array.map(((name, outputs)) =>
      outputs
      ->toResolved
      ->Pulumi.Output.apply(resolved => (
        name,
        resolved->S.reverseConvertToJsonOrThrow(schema),
      ))
    )
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray->JSON.Encode.object)
  )

// Serialize tasks dict to JSON array for the "tasks" stack export.
let serializeTasksOutputs = (pluginOutputs: Plugin.outputs): Pulumi.Output.t<JSON.t> =>
  pluginOutputs.tasks->Pulumi.Output.flatMap(tasks =>
    tasks
    ->Dict.valuesToArray
    ->Array.map(task =>
      task
      ->Task.toResolvedOutputs
      ->Pulumi.Output.apply(resolved =>
        resolved->S.reverseConvertToJsonOrThrow(ReventlessInterop.Task.resolvedOutputsSchema)
      )
    )
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(arr => arr->JSON.Encode.array)
  )

// Serialize event mappers from aggregates to JSON array for the "eventMappers" stack export.
let serializeEventMappersOutputs = (pluginOutputs: Plugin.outputs): Pulumi.Output.t<JSON.t> =>
  pluginOutputs.aggregates->Pulumi.Output.flatMap(aggregates =>
    aggregates
    ->Dict.valuesToArray
    ->Array.filterMap((agg: Aggregate.outputs) =>
      agg.eventMapper->Option.map(eventMapperOutput =>
        eventMapperOutput->Pulumi.Output.flatMap(em =>
          em
          ->EventMapper.toResolvedOutputs
          ->Pulumi.Output.apply(resolved =>
            resolved->S.reverseConvertToJsonOrThrow(
              ReventlessInterop.EventMapper.resolvedOutputsSchema,
            )
          )
        )
      )
    )
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(arr => arr->JSON.Encode.array)
  )

// Export platform admin component outputs as individual top-level Pulumi stack exports.
// Follows the same serialization pattern as exportPluginOutputs.
// Only exports non-empty component dicts to avoid cluttering stack output with empty values.
let exportPlatformOutputs = (
  ~extensionPointsOutputs: Pulumi.Output.t<array<ExtensionPoint.outputs>>,
  ~aggregatesOutputs: dict<Aggregate.outputs>,
  ~readModelsOutputs: dict<ReadModel.outputs>,
  ~dcbEventLogOutputs: option<DcbEventLog.outputs>,
  ~stateChangeSlicesOutputs: dict<StateChangeSlice.outputs>,
  ~stateViewSlicesOutputs: dict<StateViewSlice.outputs>,
  ~automationSlicesOutputs: dict<AutomationSlice.outputs>,
  ~outboundTranslationSlicesOutputs: dict<OutboundTranslationSlice.outputs>,
  ~inboundTranslationSlicesOutputs: dict<InboundTranslationSlice.outputs>,
) => {
  // Stack metadata
  exportDeploymentMetadata()

  // Extension points — always exported (the admin's primary component output)
  Pulumi.Pulumi.export(
    "extensionPoints",
    extensionPointsOutputs->Pulumi.Output.flatMap(eps =>
      eps
      ->Array.map(ep =>
        ep
        ->ExtensionPoint.toResolvedOutputs
        ->Pulumi.Output.apply(resolved => (
          ep.name,
          resolved->S.reverseConvertToJsonOrThrow(
            ReventlessInterop.ExtensionPoint.resolvedOutputsSchema,
          ),
        ))
      )
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray->JSON.Encode.object)
    ),
  )

  // Aggregates — only export if non-empty
  if aggregatesOutputs->Dict.keysToArray->Array.length > 0 {
    Pulumi.Pulumi.export(
      "aggregates",
      serializePlainDictExport(
        aggregatesOutputs,
        Aggregate.toResolvedOutputs,
        ReventlessInterop.Aggregate.resolvedOutputsSchema,
      ),
    )
  }

  // ReadModels — only export if non-empty
  if readModelsOutputs->Dict.keysToArray->Array.length > 0 {
    Pulumi.Pulumi.export(
      "readModels",
      serializePlainDictExport(
        readModelsOutputs,
        ReadModel.toResolvedOutputs,
        ReventlessInterop.ReadModel.resolvedOutputsSchema,
      ),
    )
  }

  // DCB event log — only export if present
  switch dcbEventLogOutputs {
  | Some(dcbOutputs) =>
    Pulumi.Pulumi.export(
      "dcbEventLog",
      dcbOutputs
      ->DcbEventLog.toResolvedOutputs
      ->Pulumi.Output.apply(resolved =>
        resolved->S.reverseConvertToJsonOrThrow(
          ReventlessInterop.DcbEventLog.resolvedOutputsSchema,
        )
      ),
    )
  | None => ()
  }

  // DCB slices — only export non-empty dicts
  if stateChangeSlicesOutputs->Dict.keysToArray->Array.length > 0 {
    Pulumi.Pulumi.export(
      "stateChangeSlices",
      serializePlainDictExport(
        stateChangeSlicesOutputs,
        StateChangeSlice.toResolvedOutputs,
        ReventlessInterop.StateChangeSlice.resolvedOutputsSchema,
      ),
    )
  }

  if stateViewSlicesOutputs->Dict.keysToArray->Array.length > 0 {
    Pulumi.Pulumi.export(
      "stateViewSlices",
      serializePlainDictExport(
        stateViewSlicesOutputs,
        StateViewSlice.toResolvedOutputs,
        ReventlessInterop.StateViewSlice.resolvedOutputsSchema,
      ),
    )
  }

  if automationSlicesOutputs->Dict.keysToArray->Array.length > 0 {
    Pulumi.Pulumi.export(
      "automationSlices",
      serializePlainDictExport(
        automationSlicesOutputs,
        AutomationSlice.toResolvedOutputs,
        ReventlessInterop.AutomationSlice.resolvedOutputsSchema,
      ),
    )
  }

  if outboundTranslationSlicesOutputs->Dict.keysToArray->Array.length > 0 {
    Pulumi.Pulumi.export(
      "outboundTranslationSlices",
      serializePlainDictExport(
        outboundTranslationSlicesOutputs,
        OutboundTranslationSlice.toResolvedOutputs,
        ReventlessInterop.OutboundTranslationSlice.resolvedOutputsSchema,
      ),
    )
  }

  if inboundTranslationSlicesOutputs->Dict.keysToArray->Array.length > 0 {
    Pulumi.Pulumi.export(
      "inboundTranslationSlices",
      serializePlainDictExport(
        inboundTranslationSlicesOutputs,
        InboundTranslationSlice.toResolvedOutputs,
        ReventlessInterop.InboundTranslationSlice.resolvedOutputsSchema,
      ),
    )
  }
}

// Export all plugin outputs as individual top-level Pulumi stack exports.
// Each component type is its own export key for flat, readable `pulumi stack output`.
let exportPluginOutputs = (pluginOutputs: Plugin.outputs) => {
  // Stack metadata
  exportDeploymentMetadata()

  // Scalar fields
  Pulumi.Pulumi.export("id", pluginOutputs.id->Pulumi.Output.apply(v => v->JSON.Encode.string))
  Pulumi.Pulumi.export(
    "version",
    pluginOutputs.version->Pulumi.Output.apply(v => v->JSON.Encode.string),
  )

  // Component dicts
  Pulumi.Pulumi.export(
    "aggregates",
    serializeDictExport(
      pluginOutputs.aggregates,
      Aggregate.toResolvedOutputs,
      ReventlessInterop.Aggregate.resolvedOutputsSchema,
    ),
  )
  Pulumi.Pulumi.export(
    "readModels",
    serializeDictExport(
      pluginOutputs.readModels,
      ReadModel.toResolvedOutputs,
      ReventlessInterop.ReadModel.resolvedOutputsSchema,
    ),
  )
  Pulumi.Pulumi.export(
    "extensionPoints",
    serializeDictExport(
      pluginOutputs.extensionPoints,
      ExtensionPoint.toResolvedOutputs,
      ReventlessInterop.ExtensionPoint.resolvedOutputsSchema,
    ),
  )
  Pulumi.Pulumi.export(
    "stateChangeSlices",
    serializeDictExport(
      pluginOutputs.stateChangeSlices,
      StateChangeSlice.toResolvedOutputs,
      ReventlessInterop.StateChangeSlice.resolvedOutputsSchema,
    ),
  )
  Pulumi.Pulumi.export(
    "stateViewSlices",
    serializeDictExport(
      pluginOutputs.stateViewSlices,
      StateViewSlice.toResolvedOutputs,
      ReventlessInterop.StateViewSlice.resolvedOutputsSchema,
    ),
  )
  Pulumi.Pulumi.export(
    "automationSlices",
    serializeDictExport(
      pluginOutputs.automationSlices,
      AutomationSlice.toResolvedOutputs,
      ReventlessInterop.AutomationSlice.resolvedOutputsSchema,
    ),
  )
  Pulumi.Pulumi.export(
    "outboundTranslationSlices",
    serializeDictExport(
      pluginOutputs.outboundTranslationSlices,
      OutboundTranslationSlice.toResolvedOutputs,
      ReventlessInterop.OutboundTranslationSlice.resolvedOutputsSchema,
    ),
  )
  Pulumi.Pulumi.export(
    "inboundTranslationSlices",
    serializeDictExport(
      pluginOutputs.inboundTranslationSlices,
      InboundTranslationSlice.toResolvedOutputs,
      ReventlessInterop.InboundTranslationSlice.resolvedOutputsSchema,
    ),
  )

  // DCB event log — single optional value
  Pulumi.Pulumi.export(
    "dcbEventLog",
    pluginOutputs.dcbEventLog->Pulumi.Output.flatMap(opt =>
      switch opt {
      | Some(dcbOutputs) =>
        dcbOutputs
        ->DcbEventLog.toResolvedOutputs
        ->Pulumi.Output.apply(resolved =>
          resolved->S.reverseConvertToJsonOrThrow(
            ReventlessInterop.DcbEventLog.resolvedOutputsSchema,
          )
        )
      | None => Pulumi.Output.make(Obj.magic(JSON.Encode.null))
      }
    ),
  )

  // Array exports
  Pulumi.Pulumi.export("tasks", serializeTasksOutputs(pluginOutputs))
  Pulumi.Pulumi.export("eventMappers", serializeEventMappersOutputs(pluginOutputs))

  // Fire onPluginDeployed hook with fully resolved resource data.
  switch onPluginDeployedHook.contents {
  | Some(hook) =>
    // Read deployment provenance from env vars synchronously (before Output.apply).
    let actor =
      processEnv
      ->Dict.get("GITHUB_ACTOR")
      ->Option.orElse(processEnv->Dict.get("CI_COMMIT_AUTHOR"))
      ->Option.orElse(processEnv->Dict.get("USER"))
      ->Option.getOr("local")
    let deploymentId =
      processEnv
      ->Dict.get("GITHUB_SHA")
      ->Option.orElse(processEnv->Dict.get("CI_COMMIT_SHA"))
      ->Option.getOr(Date.make()->Date.toISOString)
    let schemaFor = name =>
      componentSchemaRegistry->Dict.get(name)->Option.getOr({})
    let resolveAggregates = pluginOutputs.aggregates->Pulumi.Output.flatMap(aggs =>
      aggs
      ->Dict.toArray
      ->Array.map(((name, outputs)) =>
        outputs
        ->Aggregate.toResolvedOutputs
        ->Pulumi.Output.apply((resolved: ReventlessInterop.Aggregate.resolvedOutputs) => {
          let component: pluginDeployedComponent = {
            name,
            kind: "Aggregate",
            schema: schemaFor(name),
            resources: [],
            subComponents: [
              {role: "commandGenerator", resources: resolved.commandGenerator.resources},
              {role: "commandTopic", resources: resolved.commandTopic.resources},
              {role: "eventLog", resources: resolved.eventLog.resources},
              {role: "eventTopic", resources: resolved.eventLog.eventTopic.resources},
            ],
          }
          component
        })
      )
      ->Pulumi.Output.all
    )

    let resolveReadModels = pluginOutputs.readModels->Pulumi.Output.flatMap(rms =>
      rms
      ->Dict.toArray
      ->Array.map(((name, outputs)) =>
        outputs
        ->ReadModel.toResolvedOutputs
        ->Pulumi.Output.apply((resolved: ReventlessInterop.ReadModel.resolvedOutputs) => {
          let component: pluginDeployedComponent = {
            name,
            kind: "ReadModel",
            schema: schemaFor(name),
            resources: [],
            subComponents: [{role: "queryDb", resources: resolved.queryDb.resources}],
          }
          component
        })
      )
      ->Pulumi.Output.all
    )

    let resolveExtensionPoints = pluginOutputs.extensionPoints->Pulumi.Output.flatMap(eps =>
      eps
      ->Dict.toArray
      ->Array.map(((name, outputs)) =>
        outputs
        ->ExtensionPoint.toResolvedOutputs
        ->Pulumi.Output.apply((resolved: ReventlessInterop.ExtensionPoint.resolvedOutputs) => {
          let component: pluginDeployedComponent = {
            name,
            kind: "ExtensionPoint",
            schema: schemaFor(name),
            resources: [],
            subComponents: [
              {role: "commandTopic", resources: resolved.commandTopic.resources},
              {role: "eventTopic", resources: resolved.eventTopic.resources},
            ],
          }
          component
        })
      )
      ->Pulumi.Output.all
    )

    let resolveStateChangeSlices = pluginOutputs.stateChangeSlices->Pulumi.Output.flatMap(slices =>
      slices
      ->Dict.toArray
      ->Array.map(((name, outputs)) =>
        outputs
        ->StateChangeSlice.toResolvedOutputs
        ->Pulumi.Output.apply((resolved: ReventlessInterop.StateChangeSlice.resolvedOutputs) => {
          let component: pluginDeployedComponent = {
            name,
            kind: "StateChangeSlice",
            schema: schemaFor(name),
            resources: resolved.resources,
            subComponents: [],
          }
          component
        })
      )
      ->Pulumi.Output.all
    )

    let resolveStateViewSlices = pluginOutputs.stateViewSlices->Pulumi.Output.flatMap(slices =>
      slices
      ->Dict.toArray
      ->Array.map(((name, outputs)) =>
        outputs
        ->StateViewSlice.toResolvedOutputs
        ->Pulumi.Output.apply((resolved: ReventlessInterop.StateViewSlice.resolvedOutputs) => {
          let component: pluginDeployedComponent = {
            name,
            kind: "StateViewSlice",
            schema: schemaFor(name),
            resources: resolved.resources,
            subComponents: [{role: "queryDb", resources: resolved.queryDb.resources}],
          }
          component
        })
      )
      ->Pulumi.Output.all
    )

    let resolveAutomationSlices = pluginOutputs.automationSlices->Pulumi.Output.flatMap(slices =>
      slices
      ->Dict.toArray
      ->Array.map(((name, outputs)) =>
        outputs
        ->AutomationSlice.toResolvedOutputs
        ->Pulumi.Output.apply((resolved: ReventlessInterop.AutomationSlice.resolvedOutputs) => {
          let component: pluginDeployedComponent = {
            name,
            kind: "AutomationSlice",
            schema: schemaFor(name),
            resources: resolved.resources,
            subComponents: [{role: "queryDb", resources: resolved.queryDb.resources}],
          }
          component
        })
      )
      ->Pulumi.Output.all
    )

    let resolveOutboundTranslationSlices =
      pluginOutputs.outboundTranslationSlices->Pulumi.Output.flatMap(slices =>
        slices
        ->Dict.toArray
        ->Array.map(((name, outputs)) =>
          outputs
          ->OutboundTranslationSlice.toResolvedOutputs
          ->Pulumi.Output.apply(
            (resolved: ReventlessInterop.OutboundTranslationSlice.resolvedOutputs) => {
              let component: pluginDeployedComponent = {
                name,
                kind: "OutboundTranslationSlice",
                schema: schemaFor(name),
                resources: resolved.resources,
                subComponents: [{role: "queryDb", resources: resolved.queryDb.resources}],
              }
              component
            },
          )
        )
        ->Pulumi.Output.all
      )

    let resolveInboundTranslationSlices =
      pluginOutputs.inboundTranslationSlices->Pulumi.Output.flatMap(slices =>
        slices
        ->Dict.toArray
        ->Array.map(((name, outputs)) =>
          outputs
          ->InboundTranslationSlice.toResolvedOutputs
          ->Pulumi.Output.apply(
            (resolved: ReventlessInterop.InboundTranslationSlice.resolvedOutputs) => {
              let component: pluginDeployedComponent = {
                name,
                kind: "InboundTranslationSlice",
                schema: schemaFor(name),
                resources: resolved.resources,
                subComponents: [{role: "queryDb", resources: resolved.queryDb.resources}],
              }
              component
            },
          )
        )
        ->Pulumi.Output.all
      )

    let resolveDcbEventLog = pluginOutputs.dcbEventLog->Pulumi.Output.flatMap(opt =>
      switch opt {
      | Some(outputs) =>
        outputs
        ->DcbEventLog.toResolvedOutputs
        ->Pulumi.Output.apply((resolved: ReventlessInterop.DcbEventLog.resolvedOutputs) => {
          let component: pluginDeployedComponent = {
            name: "DcbEventLog",
            kind: "DcbEventLog",
            schema: schemaFor("DcbEventLog"),
            resources: resolved.resources,
            subComponents: [{role: "eventTopic", resources: resolved.eventTopic.resources}],
          }
          [component]
        })
      | None => Pulumi.Output.make([])
      }
    )

    // Resolve extension wiring metadata.
    let resolveExtensionWirings = pluginOutputs.extensions->Pulumi.Output.flatMap(exts =>
      pluginOutputs.id->Pulumi.Output.apply(id => {
        let pluginName = id->String.split("@")->Array.getUnsafe(0)
        let pluginVersion = id->String.split("@")->Array.getUnsafe(1)
        exts
        ->Dict.valuesToArray
        ->Array.map((ext: ReventlessInfra.Extension.outputs) => {
          // Derive provider plugin name from the extension point name
          // (e.g. "Catalog.Products" → "Catalog").
          let providerPlugin =
            ext.extensionPointName->String.split(".")->Array.getUnsafe(0)
          let wiring: extensionWiring = {
            extensionName: ext.name,
            extensionPointName: ext.extensionPointName,
            providerPlugin,
            providerVersion: "",
            subscriberPlugin: pluginName,
            subscriberVersion: pluginVersion,
          }
          wiring
        })
      })
    )

    // Collect all resolved components, fire the hook, and export the resulting
    // Output<unit> at top level so Pulumi blocks on the hook's Promise.
    let hookOutput =
      (
        pluginOutputs.id,
        pluginOutputs.version,
        resolveAggregates,
        resolveReadModels,
        resolveExtensionPoints,
        resolveStateChangeSlices,
      )
      ->Pulumi.Output.all6
      ->Pulumi.Output.flatMap(((id, version, aggs, rms, eps, scs)) =>
        (
          resolveStateViewSlices,
          resolveAutomationSlices,
          resolveOutboundTranslationSlices,
          resolveInboundTranslationSlices,
          resolveDcbEventLog,
          resolveExtensionWirings,
        )
        ->Pulumi.Output.all6
        ->Pulumi.Output.apply(((svs, autos, ots, its, dcb, wirings)) => {
          let name = id->String.split("@")->Array.getUnsafe(0)
          let meta = pluginMetadataRegistry.contents
          let info: pluginDeployedInfo = {
            name,
            version,
            environment: Pulumi.Pulumi.getStackName(),
            stackName: Pulumi.Pulumi.getStackName(),
            deployedAt: Date.make()->Date.toISOString,
            actor,
            deploymentId,
            kind: ?meta->Option.flatMap(m => m.kind),
            displayName: ?meta->Option.flatMap(m => m.displayName),
            vendor: ?meta->Option.flatMap(m => m.vendor),
            architectureType: ?meta->Option.flatMap(m => m.architectureType),
            components: Array.flat([aggs, rms, eps, scs, svs, autos, ots, its, dcb]),
            extensionWirings: wirings,
          }
          hook(info)
        })
      )
      ->Pulumi.Output.flatMap(p => p->Pulumi.Output.fromPromise)

    Pulumi.Pulumi.export("_pluginDeployedSync", hookOutput)
  | None => ()
  }
}
