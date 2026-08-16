// Local Platform — implements ReventlessInfra.Platform.T using in-memory or SQLite data structures (selected via Backend).
// Pulumi mock mode is activated automatically when Platform.Make() is applied.
//
// Example:
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// The platform starts a GraphQL server on port 4000 after all components are built.
// Stop it with TestRunner.stopGraphQLServer() in afterAll.

// Install compact Effect logger (strips timestamp=/level=/fiber= metadata from log output).
// Self-installing at module import time — must be imported before any Effect.runPromise call.
let _ = ReventlessCore.EffectLogger.install

// The local platform is a local-dev tool, so default to Debug-level logging
// (surfaces e.g. the slice/aggregate `deciding on state:` lines). An explicit
// LOG_LEVEL env var still overrides this (e.g. LOG_LEVEL=info or =silent).
ReventlessCore.EffectLogger.setDefaultMinLevel(ReventlessCore.Logger.Debug)

let log = ReventlessCore.Logger.fromEnv()

// Module-level ref to hold the platform GraphQL server instance in split mode.
// Populated by makePlatform when splitApi=true.
let platformGraphQLRef: ref<option<ReventlessGraphqlServer.GraphQL_ServerInstance.t>> = ref(None)
let getPlatformGraphQL = () => platformGraphQLRef.contents

// Module-level ref to hold the platform MCP server instance in split mode.
// Populated by makePlatform when splitApi=true.
let platformMCPRef: ref<option<MCP_ServerInstance.t>> = ref(None)

// Decode a Plugin aggregate event from the published bus envelope.
// The bus delivers the EventTopic envelope {id, meta, event} — the event
// payload lives under "event". (The previous code fed the WHOLE envelope to
// the event schema in convert mode, which "succeeded" and then threw a
// TypeError on every variant's payload access, so the Source-C status /
// UI-fragment subscription emissions never fired.) Top-level, not inside the
// functor, so the decode is unit-testable.
let decodePluginEventEnvelope = (eventJson: JSON.t): option<ReventlessCore.PluginSpec.event> =>
  switch eventJson
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("event"))
  ->Option.map(payload => payload->S.parseJsonOrThrow(ReventlessCore.PluginSpec.eventSchema)) {
  | result => result
  | exception _ => None
  }

// Decode a UiFragmentRegistry slice event from the admin DcbEventLog's published
// bus envelope — same {id, meta, event} shape as the aggregate topic above
// (DcbEventLog_Operations publishes via Message.composeEventJson'). Top-level,
// not inside the functor, so the decode is unit-testable.
let decodeUiFragmentRegistryEventEnvelope = (
  eventJson: JSON.t,
): option<ReventlessCore.UiFragmentRegistry.event> =>
  switch eventJson
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("event"))
  ->Option.map(payload =>
    payload->S.parseJsonOrThrow(ReventlessCore.UiFragmentRegistry.eventSchema)
  ) {
  | result => result
  | exception _ => None
  }

// Configurable platform — set silent=true to suppress diagnostic warnings in tests,
// splitApi=true to serve core and plugin APIs on separate ports,
// backend=Backend.Sqlite({...}) to opt into file-backed SQLite persistence.
// Usage: module Platform = Platform.MakeWithConfig({let silent = true; let splitApi = false; let cloner = false; let backend = Backend.Memory})
module MakeWithConfig = (
  Config: {
    let silent: bool
    let splitApi: bool
    let cloner: bool
    let backend: Backend.t
    let commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs
  },
): (ReventlessInfra.Platform.T with type api = unit and type role = unit) => {
  // commandHandlerConfig is accepted for transport-neutral parity with the
  // AWS platform. Lambda-specific knobs (memorySize, timeout, sqsBatchSize,
  // …) are no-ops in-memory. envVars are not propagated here because the
  // local platform has no per-component process boundary.
  let _ = Config.commandHandlerConfig
  // Activate Pulumi mock mode — must happen before any component creation.
  // Idempotent, so safe to call even if TestRunner.setup() was already called.
  let _ = TestRunner.setup()

  type api = unit
  type role = unit
  type apiTarget = Domain | Platform

  let api = ()
  let apiRole = ()

  // Wire the backend before any storage maker runs. Dispatching adapters
  // (EventLogStorage_InMemory, QueryDbStorage_InMemory, ...) read BackendState
  // inside `make` to decide whether to allocate in-memory dicts or open a
  // SQLite handle. resetOnStart truncates the file at construction.
  let _ = switch Config.backend {
  | Backend.Memory => BackendState.setMemory()
  | Backend.Postgres({pool, initialCount}) =>
    // Async setup (connect + ensureSchema + count) already ran in the
    // Backend.postgres smart constructor — the sync functor only stores the
    // ready pool and seeds the event-tap counter from the persisted totals.
    BackendState.setPostgres(~pool)
    LocalBus.seedEventTapSeq(initialCount)
  // SCOPE: Backend.Postgres persists the durable event logs (classic + DCB) via
  // the reventless-postgres runtime. Read models use the in-memory live-query
  // path — the LocalBus scan/stream registrations are synchronous, which async pg
  // cannot satisfy without a broader bus refactor; the package's
  // QueryDbStorage_Postgres remains available to deploy-time compute layers.
  // Because read models are in-memory (empty on start), they are rebuilt on every
  // startup by full-replaying the durable pg event log through the projection
  // handlers (PgProjectionCatchup, wired below). The runtime ProjectionPending
  // low-watermark (a SQLite-only persisted-checkpoint optimisation) stays off —
  // full replay needs no checkpoint.
  | Backend.Sqlite({path, resetOnStart}) =>
    if resetOnStart {
      Backend.removeFileIfExists(path)
    }
    let db = SqliteDriver.openDb(~path)
    BackendState.setSqlite(~db, ~path)
    // The object store persists beside the database under this backend (see
    // LocalObjectStore), so a reset that wipes the events wipes the bytes they
    // reference too — otherwise the session starts with orphaned uploads and
    // offload payloads no event points at. Runs after setSqlite because the
    // store reads the active backend to find its root.
    if resetOnStart {
      LocalObjectStore.reset()
    }
    // Persistent stores keep their event numbering across restarts and app
    // switches: seed the in-memory event-tap counter from the rows already on
    // disk so the timeline's #N continues instead of restarting at 1. (After a
    // reset the file is empty, so this seeds 0 — a clean session starts at #1.)
    LocalBus.seedEventTapSeq(
      EventLogStorage_Sqlite.countAll(db) + DcbEventLogStorage_Sqlite.countAll(db),
    )
    // Projection checkpoints (plan B5): the event-log storage tracks each
    // appended batch as pending; this hook resolves it once the publish cycle
    // completes (publishEvent returns only after every subscriber processed the
    // events), advancing the persisted per-read-model checkpoints to the
    // low-watermark. Startup catch-up in makePlatform replays anything below a
    // read model's checkpoint that a crash left unprojected.
    ProjectionPending.enableTracking()
    ReventlessCore.EventPublish_Callback.registerAfterPublish(async publishedEvent => {
      // Aggregate EventLog batches carry flat stored events (msgId at the top
      // level of each eventsJson entry); DcbEventLog batches carry bare event
      // payloads and expose the per-event metas separately.
      let msgIds = switch publishedEvent.metas {
      | Some(metas) => metas->Array.map(m => m.msgId)
      | None =>
        publishedEvent.eventsJson->Array.filterMap(json =>
          json
          ->JSON.Decode.object
          ->Option.flatMap(d => d->Dict.get("msgId"))
          ->Option.flatMap(JSON.Decode.string)
        )
      }
      ProjectionCheckpoint.completePublished(db, msgIds)
    })
  }

  module Bus = LocalBus.Impl({
    let capacity = None
    let silent = Config.silent
  })

  // Bridge Source B change descriptors onto the local Events transport
  // (`/default/{readModel}/{entityKey}` channels) — the in-memory analogue of
  // the AWS StateTopic → AppSync Events publish path. Harmless without
  // subscribers; the transport itself is attached in DomainGraphQL_Server.start.
  Bus.subscribeToAllStateChanges(LocalEvents_Server.broadcastStateChange)

  // Track which API target is active during deployPlugin / admin schema registration.
  // Domain = plugin-facing (default); Platform = admin/core (split mode).
  let currentDeployTarget: ref<apiTarget> = ref(Domain)

  // Plugin=subgraph scoping (mirrors the AWS plugin=source-API model): each
  // plugin's construction runs inside its own DomainGraphQL_Server scope so
  // its GraphQL registrations form a standalone subgraph, validated in
  // isolation and composed at start(). The plugin name is only known after
  // construction (via the synchronous plugin-built hook), so the scope opens
  // under a unique token and is relabeled to the plugin name afterwards.
  let pluginScopeCounter = ref(0)
  let buildPluginInScope = (
    ~makePlugin: unit => ReventlessCore.Plugin.component,
    ~builtInfos: ref<array<ReventlessCore.Plugin_Helpers.pluginBuiltInfo>>,
  ): ReventlessCore.Plugin.component => {
    pluginScopeCounter.contents = pluginScopeCounter.contents + 1
    let scopeToken = `plugin-${pluginScopeCounter.contents->Int.toString}`
    DomainGraphQL_Server.setScope(scopeToken)
    let countBefore = builtInfos.contents->Array.length
    let component = makePlugin()
    switch builtInfos.contents->Array.get(countBefore) {
    | Some(info) => DomainGraphQL_Server.relabelScope(~from=scopeToken, ~to_=info.name)
    | None => ()
    }
    DomainGraphQL_Server.resetScope()
    component
  }

  // Track which GraphQL servers have had admin schema (Plugin queries/mutations) registered.
  // Prevents double-registration when makePlatform and deployPlugin both target the same server.
  let adminRegisteredServers: ref<array<ReventlessGraphqlServer.GraphQL_ServerInstance.t>> = ref([])

  // Relay support record for domain QueryDbs (platform QueryDbs pass None).
  let domainRelaySupport: QueryDbResolvers_GraphQL.relaySupport = {
    encodeGlobalId: DomainGraphQL_Server.encodeGlobalId,
    registerNodeType: DomainGraphQL_Server.registerNodeType,
    registerNodeResolverCallback: DomainGraphQL_Server.registerNodeResolverCallback,
    nodeTypeRegistry: DomainGraphQL_Server.nodeTypeRegistry,
  }

  // Resolve the active GraphQL server based on current deploy target.
  // In unified mode always routes to DomainGraphQL_Server (single server).
  // In split mode routes based on currentDeployTarget.
  let resolveTargetGraphQL = (): ReventlessGraphqlServer.GraphQL_ServerInstance.t =>
    if !Config.splitApi {
      DomainGraphQL_Server.asInterface
    } else {
      switch currentDeployTarget.contents {
      | Domain => DomainGraphQL_Server.asInterface
      | Platform => PlatformGraphQL_Server.asInterface
      }
    }

  // Resolve the active MCP server based on current deploy target.
  // In unified mode always routes to DomainMCP_Server.
  // In split mode routes based on currentDeployTarget.
  let resolveTargetMCP = (): MCP_ServerInstance.t =>
    if !Config.splitApi {
      DomainMCP_Server.asInterface
    } else {
      switch currentDeployTarget.contents {
      | Domain => DomainMCP_Server.asInterface
      | Platform => PlatformMCP_Server.asInterface
      }
    }

  // Event-history query resolvers. Reads the same event logs the Source A
  // subscription bridge below streams, but historically and per entity.
  module EventHistoryResolvers = EventHistoryResolvers_GraphQL.Make(Bus)

  // Platform hook record — callbacks known at MakeWithConfig time plus a
  // mutable ref for admin extension points (set by makePlatform/deployPlugin
  // after Admin.construct returns, before plugins are built).
  let hooks: ReventlessCore.Plugin_Helpers.platformHooks = {
    adminExtensionPoints: ref(Pulumi.Output.make(Dict.make())),
    // Platform context — populated by makePlatform/deployPlugin before plugin build.
    scheduler: ref(None),
    schedulerRoleUrn: ref(Pulumi.Output.make("")),
    api: ref(None),
    apiRole: ref(None),
    // In-memory has a single schema (no split Domain/Platform API), so admin resolvers share `api`.
    adminApi: ref(None),
    deployTarget: ref("Domain"),
    // Phase 1: register SDL + resolver stub synchronously.
    // Pass the resolved server so the correct target (domain or platform) receives the schema.
    mutationResolverHook: (~kind, ~fields, ~commandSchema, ~commandAuthorization) => {
      let server = resolveTargetGraphQL()
      switch kind {
      | ReventlessCore.Plugin_Helpers.Aggregate =>
        CommandGeneratorResolvers_GraphQL.register(
          ~fields,
          ~commandSchema,
          ~commandAuthorization,
          ~server,
        )
      | Dcb =>
        fields->Array.forEach(field =>
          CommandGeneratorResolvers_GraphQL.registerDcb(
            ~fieldName=field,
            ~commandSchema,
            ~commandAuthorization,
            ~server,
          )
        )
      }
    },
    // Phase 2: bind generateCommand when Output.apply resolves.
    mutationBindHook: CommandGeneratorResolvers_GraphQL.bindHandler,
    // InboundTranslationSlice hooks — pass resolved server for correct target routing.
    inboundMutationResolverHook: (~fieldName, ~externalInputSchema) =>
      InboundTranslationResolvers_GraphQL.register(
        ~fieldName,
        ~externalInputSchema,
        ~server=resolveTargetGraphQL(),
      ),
    inboundMutationBindReceiveHook: InboundTranslationResolvers_GraphQL.bindReceive,
    // Register GraphQL type definitions from the generated schema fragment.
    schemaTypeRegistrationHook: sdlTypes => resolveTargetGraphQL().registerTypes(~sdlTypes),
    // Event-history queries — the historical read counterpart of the Source A
    // subscription bridged further down. Same `eventLogEntries`, so the two
    // always describe the same set of streams.
    eventQueryResolverHook: params =>
      EventHistoryResolvers.register(~server=resolveTargetGraphQL(), params),
    // MCP tools and resources — registered during plugin construction.
    // See the large lambda below; it references Bus for QueryDb lookups.
    mcpSchemaRegistrationHook: ({pluginName, mutationEntries, queryEntries, eventLogEntries, subscriptionFields}) => {
      let mcp = resolveTargetMCP()
      mcp.registerToolsFromEntries(~pluginName, ~mutationEntries, ~commandHandler=async (
        toolName,
        args,
        identity,
      ) => {
        switch CommandGeneratorResolvers_GraphQL.handlerRefs->Dict.get(toolName) {
        | Some(handlerRef) =>
          switch handlerRef.contents {
          | Some(generateCommand) =>
            let payload: ReventlessCore.CommandGenerator.payload = {
              command: toolName,
              arguments: args->Obj.magic,
              meta: {ip: [], user: identity.userId, info: `mcp/tools/${toolName}`},
              identity,
            }
            let outcome = await generateCommand(payload)->Effect.runPromise
            outcome->CommandGeneratorResolvers_GraphQL.commandOutcomeToJson->JSON.stringify
          | None => `{"error":"no handler for ${toolName}"}`
          }
        | None => `{"error":"no handler for ${toolName}"}`
        }
      })

      mcp.registerResourcesFromEntries(~pluginName, ~queryEntries, ~queryHandler=async (
        resourceName,
        uri,
      ) => {
        let segments = uri->String.split("/")
        let id = segments->Array.at(-1)->Option.getOr("")
        let queryDbName =
          ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry
          ->Dict.toArray
          ->Array.find(((_, entry)) =>
            entry.singleFieldName == resourceName || entry.listFieldName == resourceName
          )
          ->Option.map(((name, _)) => name)
          ->Option.getOr(resourceName)
        switch Bus.getQueryDb(queryDbName) {
        | Some(ops) =>
          if id->String.length > 0 && id != resourceName {
            let items = await ops.loadStream(id)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
            switch items->Array.get(0) {
            | Some(item) => item
            | None => JSON.Encode.null
            }
          } else {
            switch Bus.getQueryDbScan(queryDbName) {
            | Some(scanAll) => scanAll()->JSON.Encode.array
            | None => []->JSON.Encode.array
            }
          }
        | None => JSON.Encode.null
        }
      })

      mcp.registerEventHistoryResourcesFromEntries(
        ~pluginName,
        ~eventLogEntries,
        ~eventLogHandler=async (resourceName, uri) => {
          let pathPart = uri->String.split("?")->Array.getUnsafe(0)
          let segments = pathPart->String.split("/")
          let entityId = segments->Array.at(-1)->Option.getOr("")
          let (limit, after) = {
            let parts = uri->String.split("?")
            switch parts->Array.get(1) {
            | None => (None, None)
            | Some(qs) =>
              let params = Dict.make()
              qs
              ->String.split("&")
              ->Array.forEach(param => {
                let kv = param->String.split("=")
                switch (kv->Array.get(0), kv->Array.get(1)) {
                | (Some(k), Some(v)) => params->Dict.set(k, v)
                | _ => ()
                }
              })
              (
                params->Dict.get("limit")->Option.flatMap(v => Int.fromString(v)),
                params->Dict.get("after"),
              )
            }
          }

          let makePaginatedResponse = (
            ~events: array<JSON.t>,
            ~hasMore: bool,
            ~nextAfter: option<string>,
          ) =>
            Dict.fromArray([
              ("events", events->JSON.Encode.array),
              (
                "pagination",
                Dict.fromArray([
                  ("hasMore", hasMore->JSON.Encode.bool),
                  ("nextAfter", nextAfter->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
                ])->JSON.Encode.object,
              ),
            ])->JSON.Encode.object

          let paginate = (events: array<JSON.t>, getPosition: JSON.t => option<string>) => {
            // Positions are numeric strings; compare them as ints, not lexically
            // ("10" > "9" is false as strings) — otherwise cursor pages skip or
            // duplicate events once positions cross a digit boundary.
            let positionGt = (p, afterPos) =>
              switch (Int.fromString(p), Int.fromString(afterPos)) {
              | (Some(pi), Some(ai)) => pi > ai
              | _ => p > afterPos
              }
            let filtered = switch after {
            | Some(afterPos) =>
              let idx =
                events->Array.findIndex(e => getPosition(e)->Option.mapOr(false, p => positionGt(p, afterPos)))
              if idx >= 0 {
                events->Array.slice(~start=idx, ~end=events->Array.length)
              } else {
                []
              }
            | None => events
            }
            let (limited, hasMore) = switch limit {
            | Some(n) if filtered->Array.length > n => (
                filtered->Array.slice(~start=0, ~end=n),
                true,
              )
            | _ => (filtered, false)
            }
            let nextAfterVal = if hasMore {
              limited->Array.at(-1)->Option.flatMap(getPosition)
            } else {
              None
            }
            makePaginatedResponse(~events=limited, ~hasMore, ~nextAfter=nextAfterVal)
          }

          let matchingEntry =
            eventLogEntries->Array.find(entry =>
              resourceName->String.includes(entry.displayName->String.toLowerCase)
            )
          switch matchingEntry {
          | Some(entry) =>
            switch Bus.getEventLogReplay(entry.busKey) {
            | Some(replay) =>
              let events = await replay(entityId)
              paginate(events, e => {
                switch e->JSON.Decode.object {
                | Some(obj) =>
                  obj
                  ->Dict.get("position")
                  ->Option.flatMap(JSON.Decode.string)
                | None => None
                }
              })
            | None =>
              switch Bus.getDcbEventLogRead(entry.busKey) {
              | Some(read) =>
                let result = await read(~query=[])
                let filtered = if entityId->String.length > 0 && entityId != resourceName {
                  result.events->Array.filter(e => e.tags->Array.some(tag => tag.value == entityId))
                } else {
                  result.events
                }
                let serialized = filtered->Array.map(e =>
                  Dict.fromArray([
                    ("position", JSON.Encode.string(e.position)),
                    ("event", JSON.Encode.string(e.eventType)),
                    ("data", e.data),
                    (
                      "tags",
                      e.tags
                      ->Array.map(
                        t =>
                          Dict.fromArray([
                            ("key", JSON.Encode.string(t.key)),
                            ("value", JSON.Encode.string(t.value)),
                          ])->JSON.Encode.object,
                      )
                      ->JSON.Encode.array,
                    ),
                  ])->JSON.Encode.object
                )
                paginate(serialized, e => {
                  switch e->JSON.Decode.object {
                  | Some(obj) =>
                    obj
                    ->Dict.get("position")
                    ->Option.flatMap(JSON.Decode.string)
                  | None => None
                  }
                })
              | None => makePaginatedResponse(~events=[], ~hasMore=false, ~nextAfter=None)
              }
            }
          | None => makePaginatedResponse(~events=[], ~hasMore=false, ~nextAfter=None)
          }
        },
      )

      // Wire GraphQL WebSocket subscriptions (Source A only; Source C is
      // generated as SDL but its resolvers are currently future work).
      // Source B no longer flows through GraphQL — clients consume Events
      // channels directly. The in-memory equivalent is wired in Phase 8.
      let _ = queryEntries
      if subscriptionFields->Array.length > 0 {
        open LocalGraphQL_SubscriptionResolvers
        let server = resolveTargetGraphQL()

        // Source A: bridge each EventTopic bus topic → yoga PubSub channel
        eventLogEntries->Array.forEach(entry =>
          bridgeSourceA(
            ~subscribeToEvents=Bus.subscribeToEvents,
            ~displayName=entry.displayName,
            ~busTopicName=entry.busKey,
          )
        )

        // Register subscription SDL fields and resolvers with the GraphQL server
        let makeEntry = topic => ({fieldName: topic, topic}: subscriptionEntry)
        let sourceAEntries = eventLogEntries->Array.map(e => makeEntry(sourceATopic(e.displayName)))
        registerAll(~server, ~sdlFields=subscriptionFields, ~sourceAEntries, ~sourceBEntries=[])
      }
    },
  }

  module AggregateMaker = Aggregate_Builder.MakeWithHooks(
    Bus,
    {
      let hooks = hooks
    },
  )
  module ReadModelMaker = ReadModel_Builder.Make(Bus)
  module ExtensionPointMaker = ExtensionPoint_Builder.Make(Bus)
  module TaskMaker = Task_Builder.Make(Bus)
  module StateViewSliceMaker = StateViewSlice_Builder.Make(Bus)
  module AutomationSliceMaker = AutomationSlice_Builder.Make(Bus)
  module OutboundTranslationSliceMaker = OutboundTranslationSlice_Builder.Make(Bus)
  module InboundTranslationSliceMaker = InboundTranslationSlice_Builder.Make(Bus)

  module Aggregate = {
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (ReventlessInfra.Aggregate.T with type api = unit) => AggregateMaker.Make(
      Spec,
      Behavior,
      EventMappings,
    )
    /** Async variant — in-memory uses the same channel (no FIFO distinction). */
    module MakeAsync = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (ReventlessInfra.Aggregate.T with type api = unit) => AggregateMaker.Make(
      Spec,
      Behavior,
      EventMappings,
    )
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.ReadModel.T with module Spec = Spec and type api = unit and type role = unit
    ) => ReadModelMaker.Make(Spec, Mappings)
  }

  // In-memory has no DynamoDB streams — stream variant is identical to plain ReadModel.
  module ReadModelStream = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.ReadModel.T with module Spec = Spec and type api = unit and type role = unit
    ) => ReadModelMaker.Make(Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Mapping: ReventlessInfra.ExtensionPointMapping.Mapping,
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping.ExtensionPoint
      module CompiledMapping = ReventlessInfra.ExtensionPointMapping.Make(Mapping)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name = Mapping.Delegate.name
        // The mapping FILE's moduleUrl, not the spec's — the EventCollector
        // runtime dynamic-imports this URL to find mapOutgoingEvent.
        let moduleUrl = Mapping.moduleUrl
        let mappings: array<module(Mapping)> = [module(CompiledMapping)]
      }
      module Inner = ExtensionPointMaker.Make(Spec, Mappings)
      include Inner
    }

    module Make2 = (
      Mapping1: ReventlessInfra.ExtensionPointMapping.Mapping,
      Mapping2: ReventlessInfra.ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping1.ExtensionPoint
      module CM1 = ReventlessInfra.ExtensionPointMapping.Make(Mapping1)
      module CM2 = ReventlessInfra.ExtensionPointMapping.Make(Mapping2)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name =
          Mapping1.Delegate.name ++ "+" ++ Mapping2.Delegate.name
        // First mapping's URL — matches the user-extension merge convention.
        let moduleUrl = Mapping1.moduleUrl
        let mappings: array<module(Mapping)> = [module(CM1), module(CM2)]
      }
      module Inner = ExtensionPointMaker.Make(Spec, Mappings)
      include Inner
    }

    module Make3 = (
      Mapping1: ReventlessInfra.ExtensionPointMapping.Mapping,
      Mapping2: ReventlessInfra.ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
      Mapping3: ReventlessInfra.ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping1.ExtensionPoint
      module CM1 = ReventlessInfra.ExtensionPointMapping.Make(Mapping1)
      module CM2 = ReventlessInfra.ExtensionPointMapping.Make(Mapping2)
      module CM3 = ReventlessInfra.ExtensionPointMapping.Make(Mapping3)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name =
          Mapping1.Delegate.name ++
          "+" ++
          Mapping2.Delegate.name ++
          "+" ++
          Mapping3.Delegate.name
        // First mapping's URL — matches the user-extension merge convention.
        let moduleUrl = Mapping1.moduleUrl
        let mappings: array<module(Mapping)> = [module(CM1), module(CM2), module(CM3)]
      }
      module Inner = ExtensionPointMaker.Make(Spec, Mappings)
      include Inner
    }

    module MakeMulti = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T => ExtensionPointMaker.Make(Spec, Mappings)
  }

  module Extension = {
    module Make = (
      Mapping: ReventlessInfra.ExtensionMapping.Mapping,
    ): ReventlessInfra.Extension.Blueprint => {
      module Spec = Mapping.ExtensionPoint
      module CompiledMapping = ReventlessInfra.ExtensionMapping.Make(Mapping)
      module type Mapping = ReventlessInfra.ExtensionMapping.T
        with module ExtensionPoint := Spec
      let name = Mapping.Delegate.name
      let moduleUrl = Mapping.moduleUrl
      let delegateModuleUrl = Mapping.delegateModuleUrl
      let mappings: array<module(Mapping)> = [module(CompiledMapping)]
    }

  }

  module Task = {
    module Make = (Spec: ReventlessInfra.Task.Spec): (
      ReventlessInfra.Task.T with module Spec = Spec
    ) => TaskMaker.Make(Spec)
  }

  module Counter = Counter_Builder.Make(Bus)

  module StateChangeSlice = {
    module Make = (
      Spec: Reventless.StateChangeSlice.Spec,
      Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
    ): (ReventlessInfra.StateChangeSlice.T with module Spec = Spec) =>
      StateChangeSlice_Builder.Make(Spec, Behavior)
    /** Async variant — in-memory uses the same channel (no FIFO distinction). */
    module MakeAsync = (
      Spec: Reventless.StateChangeSlice.Spec,
      Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
    ): (ReventlessInfra.StateChangeSlice.T with module Spec = Spec) => {
      include StateChangeSlice_Builder.Make(Spec, Behavior)
      let isAsync = true
    }
  }

  module StateViewSlice = {
    module Make = (
      Spec: Reventless.StateViewSlice.Spec,
      Projection: Reventless.StateViewSlice.Projection with module Spec := Spec,
    ): (ReventlessInfra.StateViewSlice.T with module Spec = Spec) =>
      StateViewSliceMaker.Make(Spec, Projection)
  }

  // Admin UI-fragment registry (docs/plans/done/event-sourced-fragment-registries.md): the
  // platform UI-fragment registry hosted as an admin DCB slice on the admin DcbEventLog.
  // Built once and passed into Admin.construct below.
  module UiFragmentRegistrySlice = StateChangeSlice.Make(
    ReventlessCore.UiFragmentRegistry,
    ReventlessCore.UiFragmentRegistry_Behavior,
  )
  module UiFragmentsViewSlice = StateViewSlice.Make(
    ReventlessCore.UiFragments,
    ReventlessCore.UiFragments_Projection,
  )

  // In-memory has no DynamoDB streams — stream variant is identical to plain StateViewSlice.
  module StateViewSliceStream = {
    module Make = (
      Spec: Reventless.StateViewSlice.Spec,
      Projection: Reventless.StateViewSlice.Projection with module Spec := Spec,
    ): (ReventlessInfra.StateViewSlice.T with module Spec = Spec) =>
      StateViewSliceMaker.Make(Spec, Projection)
  }

  module AutomationSlice = {
    module Make = (
      Spec: Reventless.AutomationSlice.Spec,
      Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
    ): (ReventlessInfra.AutomationSlice.T with module Spec = Spec) =>
      AutomationSliceMaker.Make(Spec, Automation)
  }

  module OutboundTranslationSlice = {
    module Make = (
      Spec: Reventless.OutboundTranslationSlice.Spec,
      Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
    ): (ReventlessInfra.OutboundTranslationSlice.T with module Spec = Spec) =>
      OutboundTranslationSliceMaker.Make(Spec, Translation)
  }

  module InboundTranslationSlice = {
    module Make = (
      Spec: Reventless.InboundTranslationSlice.Spec,
      Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
    ): (ReventlessInfra.InboundTranslationSlice.T with module Spec = Spec) =>
      InboundTranslationSliceMaker.Make(Spec, Translation)
  }

  module PluginMaker = Plugin_Builder.Make(
    Bus,
    {
      let hooks = hooks
    },
  )
  module Plugin: ReventlessInfra.Plugin.T
    with type api = unit
    and type role = unit
    and type component = ReventlessCore.Plugin.component = {
    type api = unit
    type role = unit
    type component = ReventlessCore.Plugin.component
    let make = PluginMaker.make
    let makeAutoUIManifest = PluginMaker.makeAutoUIManifest
    let makePluginDefinition = PluginMaker.makePluginDefinition
  }

  module EventCollectorChannel = LocalEventCollectorChannel.Make(Bus)
  module QE = LocalQueryEngine.Make(Bus)

  // Admin-internal Plugin aggregate. Constructed here so it can be threaded into
  // Admin.construct's ~aggregates parameter — registerAdminAggregateMutations then
  // wires Platform_Plugin_Activate / Platform_Plugin_Deactivate through the standard
  // CommandGenerator auto-flow (same path user-plugin aggregates use). Internal-protocol
  // variants (Heartbeat, Connect, Disconnect, ReportIncompatibility) carry `@noApi` and
  // are filtered out before SDL/resolver generation.
  module LocalPluginAggregate: ReventlessInfra.Aggregate.T with type api = unit = AggregateMaker.Make(
    ReventlessCore.PluginSpec,
    ReventlessCore.PluginBehavior,
    ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
  )

  // Admin Plugin read model — driven by LocalPluginAggregate's event topic via
  // the real projection subscriptions (same path as AWS). PluginsReadModel is the
  // name-keyed current view ("Plugins"). The projection module re-exports `mappings`
  // and an inner `Mappings` submodule but doesn't satisfy
  // `Reventless.Projection.Mappings` at the top level (the `Mapping` type lives in
  // the submodule), so we flatten it into a wrapper module — mirrors the AWS
  // Platform.res PluginReadModelMappings wrapper.
  module PluginsReadModelMappings: Reventless.Projection.Mappings
    with module Target := ReventlessCore.PluginsReadModelSpec = {
    module M = ReventlessCore.PluginsProjection.Mappings
    module type Mapping = M.Mapping
    let moduleUrl: string = ReventlessCore.PluginsProjection.moduleUrl
    let mappings: array<module(Mapping)> = ReventlessCore.PluginsProjection.mappings
  }
  module PluginsReadModel = ReadModelMaker.MakeNoResolver(
    ReventlessCore.PluginsReadModelSpec,
    PluginsReadModelMappings,
  )

  module Admin = ReventlessCore.Platform_Admin.Make(
    LocalRuntimeEnvironment,
    EventCollectorChannel,
    QE,
    LocalClonerRunner,
    ReventlessCore.PluginRuntime_Builder_Micro.Make(
      LocalRuntimeEnvironment,
      EventCollectorChannel,
    ),
    LocalDcbEventLogStorage.Make(Bus),
    LocalEventTopicPublisher.Make(Bus),
    LocalCommandTopicChannel.Make(Bus),
    LocalCommandTopicChannel.Make(Bus),
    {
      let silent = Config.silent
      let splitApi = Config.splitApi
      let cloner = Config.cloner
      let hooks = hooks
    },
  )

  module type PluginMaker = {
    let make: unit => Plugin.component
  }

  let makeScheduler = () => {
    module SP = LocalScheduledPublisher.Make(Bus)
    module S = ReventlessCore.Scheduler_Builder.Make(SP)
    let component = S.make()
    component->ReventlessCore.Component.operations
  }

  let graphqlDebug = NodeProcess.env->Dict.get("GRAPHQL_DEBUG")->Option.isSome

  // Per-session server ports for the VS Code local platform runner (features
  // plan Phase 9). The runner spawns one platform child per app folder; default
  // ports (4000/4001/3001/3002) collide when several run, so each is overridable
  // via env. Defaults preserve today's behaviour for all non-runner callers.
  let resolvePort = (key, fallback) =>
    NodeProcess.env->Dict.get(key)->Option.flatMap(v => Int.fromString(v))->Option.getOr(fallback)
  let domainPort = resolvePort("REVENTLESS_DOMAIN_PORT", 4000)
  let domainMcpPort = resolvePort("REVENTLESS_DOMAIN_MCP_PORT", 3001)
  let platformPort = resolvePort("REVENTLESS_PLATFORM_PORT", 4001)
  let platformMcpPort = resolvePort("REVENTLESS_PLATFORM_MCP_PORT", 3002)

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpSupported

  // Content-address the two large pluginDefinition fields into the process-local
  // object store, exactly as the AWS platform does into its offload bucket. Local
  // has no bucket, but it does have an object store — and leaving the fields
  // inline here meant every connect handshake carried a whole plugin structure
  // through the command log, and that local never exercised the offload path the
  // deployed platform takes. Registered once at platform setup, before any plugin
  // is built, since the hook fires during graph construction.
  ReventlessCore.Plugin_Helpers.registerOffload((~store, ~bytes) => {
    let hash = NodeCrypto.sha256Hex(bytes)
    let key = "sha256/" ++ hash
    LocalObjectStore.putOffload(~key, ~bytes)
    {Reventless.Offload.store, key, hash, bytes: bytes->String.length}
  })

  // ---------------------------------------------------------------------------
  // Shared helpers — used by both makePlatform and deployPlugin.
  // ---------------------------------------------------------------------------

  // The Plugin QueryDb store ("Plugins") is now owned by the real PluginsReadModel
  // projection (wired into Admin.construct ~readModels). QueryDbStorage_InMemory
  // registers it in the Bus under PluginsReadModelSpec.name, so the admin query
  // resolvers / status gate that scan `Bus.getQueryDbScan(pluginQueryDbName)` pick
  // it up automatically — no hand-rolled seed store here anymore. Rows are produced
  // by dispatching a synthetic `Connect(pluginDefinition)` to LocalPluginAggregate
  // (see connectPlugin).

  // In-memory store for plugin structures, keyed by plugin ID.
  let pluginStructuresStore: ref<dict<Reventless.Plugin.pluginStructure>> = ref(Dict.make())

  // Bake the curated manifest from the plugin components directly rather than
  // from `pluginStructuresStore`: a structure only exists once its Output
  // resolves, so a synchronous read of that store at the end of `makePlatform`
  // sees an empty dict. Emitting once the last plugin's structure has landed is
  // both the earliest correct moment and the only one that cannot bake a
  // half-registered platform.
  let bakeManifest = (
    ~pluginComponents: array<ReventlessCore.Plugin.component>,
    ~config: ReventlessInfra.Platform.bakedManifest,
  ) => {
    let resolved: array<(string, Reventless.Plugin.pluginStructure)> = []
    let expected = pluginComponents->Array.length
    pluginComponents->Array.forEach(plugin => {
      let outputs: ReventlessInfra.Plugin.outputs = plugin->ReventlessCore.Component.outputs
      let _ =
        (outputs.id, outputs.pluginStructure)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((id, ps)) => {
          switch ps {
          | Some(def) => resolved->Array.push((id, def))
          | None => ()
          }
          if resolved->Array.length === expected {
            BakedManifest.emit(~structures=resolved, ~config)
          }
        })
    })
  }

  // The object stores a plugin's fields declared, as `{plugin}.{store}` keys.
  let declaredStoresOf = (structure: Reventless.Plugin.pluginStructure) =>
    structure.requiredStores->Option.getOr([])

  let seedPluginStructuresStore = (~pluginComponents: array<ReventlessCore.Plugin.component>) => {
    pluginComponents->Array.forEach(plugin => {
      let outputs: ReventlessInfra.Plugin.outputs = plugin->ReventlessCore.Component.outputs
      let _ =
        (outputs.id, outputs.pluginStructure)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((id, ps)) => {
          switch ps {
          | Some(def) =>
            pluginStructuresStore.contents->Dict.set(id, def)
            // Inside the apply, not after the forEach: the structure only exists
            // once the Output resolves, so anything reading
            // `pluginStructuresStore` synchronously below reads an empty dict.
            declaredStoresOf(def)->Array.forEach(qualified =>
              // Registering the store is what lets an uploaded object be attributed
              // to the plugin that declared it, the way an S3 key's prefix does —
              // under the served `uploads/` prefix locally, for the reason
              // LocalObjectStore.localPrefixFor gives.
              LocalObjectStore.registerStore(
                ~qualified,
                ~prefix=LocalObjectStore.localPrefixFor(~qualified),
              )
            )
            // Two plugins declaring one store name is refused by the deployed
            // platform before it provisions anything. Local provisions no stores, so
            // nothing here breaks — but this is the only place a developer meets the
            // rule while the fix is still free: once a store has deployed, its minted
            // refs are in an append-only event log and renaming it strands them.
            // Hence a warning at composition, and the authoritative refusal at deploy.
            //
            // Checked against every store registered so far rather than this
            // plugin's own, since a collision is by definition between two plugins.
            ReventlessCore.StorePrefixCollision.collisionsFor(
              ~stores=LocalObjectStore.declaredStoreList()->Array.map(((qualified, prefix)) => {
                ReventlessCore.StorePrefixCollision.qualified,
                prefix,
              }),
            )->Array.forEach(c =>
              log.warn(~comp="Platform:plugins", ReventlessCore.StorePrefixCollision.collisionMessage(c))
            )
          | None => ()
          }
        })
    })
  }

  // Bus keys for the admin Plugin aggregate (name-keyed). ComponentType.toName maps
  // CommandTopic → "CmdTopic" and EventTopic → "EventTopic".
  let pluginCmdTopicKey = ReventlessCore.PluginSpec.name ++ "Aggr" ++ "CmdTopic" // "PluginAggrCmdTopic"
  let pluginEventTopicKey =
    ReventlessCore.PluginSpec.name ++ "Aggr" ++ "EventTopic" // "PluginAggrEventTopic"

  // Dispatch a Plugin aggregate command in-process via the Bus command topic. The
  // body is the {id, meta, command} shape LocalCommandTopicChannel produces; the
  // aggregate id is the plugin NAME. dispatchCommand parks the command until the
  // aggregate's handler is registered (LocalBus pending-queue), so call-before-wire
  // is safe.
  let dispatchPluginCommand = (~pluginName: string, ~command: ReventlessCore.PluginSpec.command) => {
    let cmdJson: Reventless.Message.commandJson = {
      id: pluginName,
      meta: ReventlessCore.Message.generateMeta(~service=ReventlessCore.PluginSpec.name),
      commandJson: command->S.reverseConvertToJsonOrThrow(ReventlessCore.PluginSpec.commandSchema),
    }
    Bus.dispatchCommand(pluginCmdTopicKey, ReventlessCore.CommandTopic.encodeCommandJson(cmdJson))
  }

  // Bus key for the shared admin DCB command topic, derived exactly as
  // Dcb_Builder + CommandTopic_Builder name the channel:
  // pluginId -> +"Dcb" -> +CmdTopic ("PlatformDcbCmdTopic").
  let adminDcbCmdTopicKey = {
    module CT = ReventlessCore.ComponentType
    (ReventlessCore.Platform_Admin_Structure.pluginId ++ "Dcb")->CT.name(CT.CommandTopic)
  }

  // Dispatch a UiFragmentRegistry slice command in-process via the shared admin
  // DCB command topic. The DCB filtering handler routes by the command's variant
  // tag to the slice handler registered by Admin.construct's DcbBuilder. The real
  // platform routes RegisterUiFragment through the admin PluginExtensionPoint's
  // UI-fragment mapping; the local platform has no admin EP component (Connect is
  // likewise dispatched straight to the Plugin aggregate), so this is the local
  // analogue of that mapping's PublishCommand. Keyed by bare plugin NAME —
  // dispatchCommand parks until the slice handler registers, so call-before-wire
  // is safe.
  let dispatchUiFragmentCommand = (
    ~pluginName: string,
    ~command: ReventlessCore.UiFragmentRegistry.command,
  ) => {
    let cmdJson: Reventless.Message.commandJson = {
      id: pluginName,
      meta: ReventlessCore.Message.generateMeta(~service=ReventlessCore.UiFragmentRegistry.name),
      commandJson: command->S.reverseConvertToJsonOrThrow(
        ReventlessCore.UiFragmentRegistry.commandSchema,
      ),
    }
    Bus.dispatchCommand(adminDcbCmdTopicKey, ReventlessCore.CommandTopic.encodeCommandJson(cmdJson))
  }

  // Subscription topics for the admin live-update channels.
  let pluginStatusSubTopic = "onPluginStatusChange"
  let uiFragmentSubTopic = "onUIFragmentChange"

  // Bus key + service identity of the admin DcbEventLog's event topic. The
  // Platform_Admin construct name is `Platform_Admin_Structure.pluginId`;
  // DcbEventLog_Builder hands that name to EventTopic_Builder, whose publisher
  // registers under `<name>EventTopic`, and DcbEventLog_Operations stamps every
  // published event's meta.service with `<name>DcbEventLog`.
  let adminDcbEventTopicKey = {
    module CT = ReventlessCore.ComponentType
    ReventlessCore.Platform_Admin_Structure.pluginId->CT.name(CT.EventTopic)
  }
  let adminDcbServiceName = {
    module CT = ReventlessCore.ComponentType
    ReventlessCore.Platform_Admin_Structure.pluginId->CT.name(CT.DcbEventLog)
  }

  // Relocated Source-C emission: subscribe to the Plugin aggregate's event topic
  // (lifecycle status) and the admin DcbEventLog event topic (UiFragmentRegistry
  // slice events — the Plugin aggregate no longer emits UIFragment* events) and
  // fan each event out to the matching GraphQL subscription. Status
  // flows from folding aggregate events (Connect / Activate / Deactivate / Retire),
  // not from direct QueryDb writes, so the subscription emission lives here rather
  // than inside the mutation resolvers. Idempotent: registered once per platform
  // instance (guarded by pluginEventsSubscribed). Subscribe BEFORE any Connect
  // dispatch — LocalBus drops events with no subscribers.
  let pluginEventsSubscribed = ref(false)
  let subscribeToPluginEvents = () =>
    if !pluginEventsSubscribed.contents {
      pluginEventsSubscribed := true
      let publishStatus = (~name, ~status) =>
        LocalGraphQL_SubscriptionResolvers.publish(
          pluginStatusSubTopic,
          JSON.Encode.object(
            Dict.fromArray([
              ("pluginId", JSON.Encode.string(name)),
              ("status", JSON.Encode.string(status)),
            ]),
          ),
        )
      let publishUIFragment = (~name, ~changeKind, ~manifest) =>
        LocalGraphQL_SubscriptionResolvers.publish(
          uiFragmentSubTopic,
          JSON.Encode.object(
            Dict.fromArray([
              ("pluginId", JSON.Encode.string(name)),
              ("changeKind", JSON.Encode.string(changeKind)),
              ("manifest", manifest),
            ]),
          ),
        )
      let manifestJson = (m: Reventless.Plugin.uiFragmentManifest) =>
        m->S.reverseConvertToJsonOrThrow(Reventless.Plugin.uiFragmentManifestSchema)
      Bus.subscribeToEvents(pluginEventTopicKey, async (_service, _meta, eventJson) => {
        switch decodePluginEventEnvelope(eventJson) {
        | Some(VersionConnected(def))
        | Some(VersionActivated(def))
        | Some(VersionPromoted(def)) =>
          publishStatus(~name=def.name, ~status="Connected")
        | Some(VersionDisconnected(def)) => publishStatus(~name=def.name, ~status="Disconnected")
        | Some(VersionDeactivated(def)) => publishStatus(~name=def.name, ~status="Inactive")
        | Some(VersionRetired(def)) => publishStatus(~name=def.name, ~status="Retired")
        | Some(VersionDetected(_))
        | Some(VersionSuperseded(_))
        | Some(IncompatiblePluginDetected(_))
        | None => ()
        }
      })
      // UI-fragment live updates — sourced from the UiFragmentRegistry slice's
      // events on the shared admin DcbEventLog topic. The slice's `pluginId` is
      // already the bare plugin name (the EP mapping keys the registry by name).
      // The service guard keeps this decoder scoped to DcbEventLog-published
      // envelopes as further admin slices join the shared log.
      Bus.subscribeToEvents(adminDcbEventTopicKey, async (service, _meta, eventJson) =>
        if service == adminDcbServiceName {
          switch decodeUiFragmentRegistryEventEnvelope(eventJson) {
          | Some(UiFragmentRegistered({pluginId, manifest})) =>
            publishUIFragment(
              ~name=pluginId,
              ~changeKind="Registered",
              ~manifest=manifestJson(manifest),
            )
          | Some(UiFragmentUpdated({pluginId, newManifest})) =>
            publishUIFragment(
              ~name=pluginId,
              ~changeKind="Updated",
              ~manifest=manifestJson(newManifest),
            )
          | Some(UiFragmentDeregistered({pluginId})) =>
            publishUIFragment(~name=pluginId, ~changeKind="Deregistered", ~manifest=JSON.Encode.null)
          | None => ()
          }
        }
      )
    }

  // Drive the admin Plugin read models the same way AWS does: build a
  // `pluginDefinition` from the constructed plugin component outputs and dispatch a
  // synthetic `Connect(def)` to LocalPluginAggregate, keyed by the plugin NAME (the
  // Plugin aggregate is name-keyed). The Plugin aggregate emits `VersionConnected`
  // (+ `VersionSuperseded`) on its event topic; the real
  // PluginsProjection subscription (registered by
  // Admin.construct ~readModels) folds those events into the "Plugins" current view
  // QueryDb store. This replaces the previous
  // direct-write seed.
  //
  // dispatchCommand parks the command until LocalPluginAggregate's handler is
  // registered (LocalBus pending-queue), so ordering against async wiring is safe.
  // The aggregate's emitted events feed the read-model EventCollectors via the bus;
  // by the time projection handlers are live the parked command drains.
  let connectPlugin = (~pluginComponents: array<ReventlessCore.Plugin.component>) => {
    pluginComponents->Array.forEach(plugin => {
      let outputs: ReventlessInfra.Plugin.outputs = plugin->ReventlessCore.Component.outputs
      let _ =
        (
          outputs.id,
          outputs.version,
          outputs.eventCollector,
          outputs.extensionPoints,
          outputs.extensions,
          outputs.apiSchemaFragment,
          outputs.uiFragments,
          outputs.pluginStructure,
        )
        ->Pulumi.Output.all8
        ->Pulumi.Output.apply(((
          id,
          version,
          eventCollector,
          extensionPoints,
          extensions,
          apiSchemaFragment,
          uiFragments,
          pluginStructure,
        )) => {
          let pluginName = id->String.split("@")->Array.get(0)->Option.getOr(id)
          let pluginDefinition: Reventless.Plugin.pluginDefinition = {
            id,
            name: pluginName,
            version,
            eventCollector: eventCollector.name,
            extensionPoints: extensionPoints
            ->Dict.toArray
            ->Array.map(
              ((epName, ep: ReventlessInfra.ExtensionPoint.outputs)) => {
                Reventless.Plugin.name: epName,
                commandTopic: epName,
                eventTopic: ep.name,
              },
            ),
            extensions: extensions
            ->Dict.toArray
            ->Array.map(
              ((_, ext: ReventlessInfra.Extension.outputs)) => {
                Reventless.Plugin.name: ext.name,
                extensionPointName: ext.extensionPointName,
                dcbSources: [],
              },
            ),
            extensionProtocols: [],
            apiSchemaFragment: apiSchemaFragment->Option.map(f =>
              f->ReventlessCore.Plugin_Helpers.offloadPayload(
                ~schema=Reventless.Plugin.apiSchemaFragmentSchema,
                ~store="pluginApiFragments",
              )
            ),
            apiTarget: None,
            structure: pluginStructure->Option.map(s =>
              s->ReventlessCore.Plugin_Helpers.offloadPayload(
                ~schema=Reventless.Plugin.pluginStructureSchema,
                ~store="pluginStructures",
              )
            ),
            dcbEventLog: None,
            kind: Domain,
          }
          // Dispatch Connect(def) to the Plugin aggregate (id = plugin NAME).
          let _ = dispatchPluginCommand(
            ~pluginName,
            ~command=ReventlessCore.PluginSpec.Connect(pluginDefinition),
          )
          // Register the UI-fragment manifest with the UiFragmentRegistry slice
          // (via the shared admin DCB command topic), so the UiFragments
          // StateViewSlice populates in-process. `at` mirrors the EP mapping's
          // command-meta timestamp threading.
          switch uiFragments {
          | Some(manifest) =>
            let _ = dispatchUiFragmentCommand(
              ~pluginName,
              ~command=ReventlessCore.UiFragmentRegistry.RegisterUiFragment({
                pluginId: pluginName,
                manifest,
                at: Date.make()->Date.toISOString,
              }),
            )
          | None => ()
          }
        })
    })
  }

  // Extract extension wiring metadata from a plugin's outputs.
  // Returns an Output so the caller can chain on the resolved value.
  let extractExtensionWirings = (
    pluginName: string,
    pluginVersion: string,
    pluginOutputs: ReventlessInfra.Plugin.outputs,
  ): Pulumi.Output.t<array<ReventlessCore.Plugin_Helpers.extensionWiring>> => {
    pluginOutputs.extensions->Pulumi.Output.apply(exts =>
      exts
      ->Dict.valuesToArray
      ->Array.map((ext: ReventlessInfra.Extension.outputs) => {
        let providerPlugin =
          ext.extensionPointName->String.split(".")->Array.getUnsafe(0)
        let wiring: ReventlessCore.Plugin_Helpers.extensionWiring = {
          extensionName: ext.name,
          extensionPointName: ext.extensionPointName,
          providerPlugin,
          providerVersion: "",
          subscriberPlugin: pluginName,
          subscriberVersion: pluginVersion,
        }
        wiring
      })
    )
  }

  // Fire onPluginDeployed hooks for each plugin that was built.
  let firePluginDeployedHooks = (
    ~builtInfos: array<ReventlessCore.Plugin_Helpers.pluginBuiltInfo>,
    ~pluginOutputs=?,
  ) => {
    let environment = Pulumi.Pulumi.getStackName()
    builtInfos->Array.forEachWithIndex((info, i) => {
      switch ReventlessCore.Plugin_Helpers.onPluginDeployedHook.contents {
      | Some(hook) =>
        let wiringsOutput = switch pluginOutputs->Option.flatMap(arr => arr->Array.get(i)) {
        | Some(outputs) => extractExtensionWirings(info.name, info.version, outputs)
        | None => Pulumi.Output.make([])
        }
        let _ = wiringsOutput->Pulumi.Output.apply(wirings => {
          let deployedInfo: ReventlessCore.Plugin_Helpers.pluginDeployedInfo = {
            name: info.name,
            version: info.version,
            environment,
            stackName: environment,
            deployedAt: Date.make()->Date.toISOString,
            actor: "local",
            deploymentId: Date.make()->Date.toISOString,
            kind: ?info.kind,
            displayName: ?info.displayName,
            vendor: ?info.vendor,
            architectureType: ?info.architectureType,
            components: info.components->Array.map(
              (c): ReventlessCore.Plugin_Helpers.pluginDeployedComponent => {
                name: c.name,
                kind: c.kind,
                schema: c.schema,
                resources: [],
                subComponents: [],
              },
            ),
            extensionWirings: wirings,
          }
          let _ = hook(deployedInfo)
        })
      | None => ()
      }
    })
  }

  // Start all servers. In split mode this is deferred — called explicitly by the
  // caller after all makePlatform/deployPlugin calls are complete. In unified mode
  // this is a no-op (start() is called inline inside makePlatform/deployPlugin).
  let startServers = () => {
    if Config.splitApi {
      // Hydrate Login store from .reventless/users.yaml (or ~users/~usersFile
      // if provided programmatically) before the Domain server accepts
      // requests. Unified mode does this in makePlatform; split mode defers
      // server startup to here so it must do the same.
      UserStore.autoLoadOnce()
      DomainGraphQL_Server.start(~port=domainPort, ())
      DomainMCP_Server.start(~port=domainMcpPort, ())
      PlatformGraphQL_Server.start(
        ~port=platformPort,
        ~contextFactory=Auth_GraphqlContext.buildAuthContext,
        (),
      )
      PlatformMCP_Server.start(~port=platformMcpPort, ())
    }
    if graphqlDebug {
      DomainGraphQL_Server.printDiagnostics()
      DomainMCP_Server.printDiagnostics()
      if Config.splitApi {
        PlatformGraphQL_Server.printDiagnostics()
        PlatformMCP_Server.printDiagnostics()
      }
    }
    // Announce this platform — endpoint AND the store it opened — so `seed` and
    // `seed:reset` can address it instead of inferring a store from their own
    // environment. Here rather than in makePlatform because this is the one
    // point both API modes pass through once the servers are actually up: in
    // split mode they start just above, in unified mode makePlatform started
    // them and this still runs before the process serves its first request.
    let (kind, path) = BackendState.describeStore()
    LocalPlatformRegistry.register(
      ~port=domainPort,
      ~endpoint=`http://localhost:${domainPort->Int.toString}/graphql`,
      ~loginEndpoint=`http://localhost:${domainPort->Int.toString}/__inmemory/login`,
      ~store={kind, path},
    )
    // Fire onPlatformDeployed after all servers are started so late-deployed
    // plugins (e.g. PlatformInspector) have their handler refs populated.
    ReventlessCore.Plugin_Helpers.firePlatformDeployedHook({
      name: "local",
      environment: Pulumi.Pulumi.getStackName(),
      region: "local",
      domainApiEndpoint: "http://localhost:4000/graphql",
      domainApiRoleArn: "local",
      platformApiEndpoint: if Config.splitApi {
        "http://localhost:4001/graphql"
      } else {
        "http://localhost:4000/graphql"
      },
      platformApiRoleArn: "local",
      adminResources: [],
    })
  }

  // -- Admin mutation helpers --------------------------------------------------
  // Transform SDL mutation fields so their return type is CommandResult! instead
  // of the String! placeholder that GraphQL_FragmentGenerator emits.
  let adminMutationSdl = (mutations: array<string>): array<string> =>
    mutations->Array.map(field => {
      let suffix = ": String!"
      let n = field->String.length - suffix->String.length
      if n > 0 && field->String.endsWith(suffix) {
        field->String.slice(~start=0, ~end=n) ++ ": CommandResult!"
      } else {
        field
      }
    })

  // Build a CommandAccepted JSON object for admin mutation responses.
  let commandAccepted = (~msgId, ~entityId=?) =>
    Dict.fromArray([
      ("__typename", JSON.Encode.string("CommandAccepted")),
      ("msgId", JSON.Encode.string(msgId)),
      ("entityId", entityId->Option.map(JSON.Encode.string)->Option.getOr(JSON.Encode.null)),
      ("eventCount", JSON.Encode.int(0)),
    ])->JSON.Encode.object

  // Build a Relay connection JSON object for admin list query responses.
  let connectionResponse = (items: array<JSON.t>): JSON.t => {
    let edges =
      items->Array.mapWithIndex((item, i) =>
        Dict.fromArray([("node", item), ("cursor", Int.toString(i)->JSON.Encode.string)])->JSON.Encode.object
      )
    let hasItems = edges->Array.length > 0
    Dict.fromArray([
      ("edges", edges->JSON.Encode.array),
      (
        "pageInfo",
        Dict.fromArray([
          ("hasNextPage", JSON.Encode.bool(false)),
          ("hasPreviousPage", JSON.Encode.bool(false)),
          ("startCursor", hasItems ? JSON.Encode.string("0") : JSON.Encode.null),
          (
            "endCursor",
            hasItems ? JSON.Encode.string(Int.toString(edges->Array.length - 1)) : JSON.Encode.null,
          ),
        ])->JSON.Encode.object,
      ),
    ])->JSON.Encode.object
  }

  // Generic admin composite-key / index query resolvers. `GraphQL_FragmentGenerator`
  // now emits `<single>Items` (sub-id) and `<single>By<Index>` (GSI) query fields
  // for any admin read model whose spec declares a `subIdConfig` / `config.indexes`
  // (see PluginBaseFragment.res — closing the admin/ordinary parity gap). Register
  // the matching resolvers here, driven off the same `PluginBaseFragment.queryEntries`
  // the SDL is generated from, so the local GraphQL surface stays in lockstep with
  // the SDL instead of positional hand-wiring. Purely additive — `single` / `list`
  // keep their per-entry handling registered above. `~live` toggles real partition
  // loads (plugin path) vs empty stubs (platform-only path with no QueryDb seeded).
  let registerAdminItemsAndIndexResolvers = (~queryResolvers, ~live: bool) =>
    ReventlessCore.PluginBaseFragment.queryEntries->Array.forEach(entry => {
      let queryDbName = entry.specName->Option.getOr(entry.returnTypeName)
      // `<single>Items(id, …)` — all rows under one partition (composite key).
      switch entry.subIdField {
      | Some(_) =>
        queryResolvers->Dict.set(
          entry.singleFieldName ++ "Items",
          async (_root, args, _ctx): JSON.t =>
            if !live {
              connectionResponse([])
            } else {
              let id =
                args
                ->JSON.Decode.object
                ->Option.flatMap(d => d->Dict.get("id"))
                ->Option.flatMap(JSON.Decode.string)
                ->Option.getOr("")
              let items = switch Bus.getQueryDb(queryDbName) {
              | Some(ops) =>
                await ops.loadStream(id)
                ->Stream.runCollect
                ->Effect.catchAll(_ => Effect.succeed([]))
                ->Effect.runPromise
              | None => []
              }
              connectionResponse(items)
            },
        )
      | None => ()
      }
      // `<single>By<Index>` — no admin read model declares an `@index` yet, so this
      // branch is currently inert. The empty-connection resolver keeps the SDL field
      // (when the first admin GSI is added, Part 2b) from being resolver-less; the
      // indexed scan is fleshed out together with that first concrete index.
      switch entry.indexQueries {
      | Some(indexes) =>
        indexes->Array.forEach((ic: Reventless.ReadModel.indexConfig) => {
          let stripped =
            ic.index->String.startsWith("by") && ic.index->String.length > 2
              ? ic.index->String.slice(~start=2, ~end=ic.index->String.length)
              : ic.index
          let fieldName = entry.singleFieldName ++ "By" ++ stripped->String.capitalize
          queryResolvers->Dict.set(fieldName, async (_root, _args, _ctx): JSON.t =>
            connectionResponse([])
          )
        })
      | None => ()
      }
    })

  // In-memory ignores the infrastructure half of `~hostUiBundle` — the host shell
  // is served from the installed package's own `dist/`, not from a CDN. What a
  // deployment *says* is honoured, in the same three files the AWS deploy writes
  // beside each other: `bakedManifest` through `BakedManifest`, `shellConfig`
  // through `ShellConfig`, which overlays the served `config.json` the way the
  // AWS deploy composes the one it writes, and `uiHintsFile` through `UiHints`,
  // which replaces the served hints file the way the deploy uploads it.
  type hostUiBundleConfig = {
    assetsDir?: string,
    bundleVersion?: string,
    // `makePlatform` serves the declared file in place of the host-shell
    // package's own dev-mode fallback, which an undeclared platform keeps.
    uiHintsFile?: string,
    // `makePlatform` writes the curated manifest where the local host-shell
    // serves its static assets from, and points `config.json` at it.
    bakedManifest?: ReventlessInfra.Platform.bakedManifest,
    // AWS host-ui deploy knobs — carried to satisfy the shared Platform.T
    // signature; the in-memory platform provisions no infrastructure and
    // ignores them.
    geocoderPlaceIndex?: ReventlessInfra.Platform.geocoderIndex,
    uploadBucket?: ReventlessInfra.Platform.objectStore,
    // Still ignored: a mode is a shell *build* input locally, turned on in the
    // host-shell package's own `public/config.json`, where the AWS deploy has to
    // write it into the config.json it hosts.
    viewModes?: array<ReventlessInfra.Platform.viewMode>,
    // Merged into the served `config.json` verbatim, as on AWS — the keys the
    // shell owns and neither platform computes (`appName`, `elevatedGroups`, …).
    shellConfig?: dict<JSON.t>,
  }
  let makePlatform = (
    ~version,
    ~plugins: array<module(PluginMaker)>,
    ~hostUiBundle: option<hostUiBundleConfig>=?,
  ) => {
    log.info(~comp="Platform", `v${version}`)
    log.info(
      ~comp="Platform",
      `silent: ${Config.silent->Bool.toString}, splitApi: ${Config.splitApi->Bool.toString}, cloner: ${Config.cloner->Bool.toString}`,
    )
    log.info(
      ~comp="Platform",
      switch Config.backend {
      | Backend.Memory => "backend: memory"
      | Backend.Postgres({connection}) => `backend: postgres (${connection}, event-logs only)`
      | Backend.Sqlite({path, resetOnStart}) =>
        `backend: sqlite (${path}${resetOnStart ? ", resetOnStart" : ""})`
      },
    )
    // Runtime extension seam. Fired before anything is built, so an extension's
    // interception and publish hooks are registered before the first command or
    // query can reach them.
    //
    // Off Lambda the seam means something slightly different, and deliberately
    // so: every component runs in THIS process, so there is one cold start, not
    // one per runtime. Firing per hosted component would hand an extension N
    // identities for a single process and re-run registrations that are
    // module-level refs anyway. `Platform` is the honest kind for a runtime that
    // hosts all of them; an extension that routes on kind should treat this as
    // "everything", which is what it is.
    ReventlessCore.RuntimeExtension.notifyColdStart(
      ~runtimeKind=ReventlessCore.ComponentType.Platform,
      ~component="LocalPlatform",
      ~plugin=ReventlessCore.ResourceAttribution.current.contents.plugin,
      ~platform=ReventlessCore.ResourceAttribution.current.contents.platform,
    )

    // Projection catch-up bound (plan B5): the highest persisted event position
    // BEFORE this session appends anything. Catch-up replays only (checkpoint,
    // bound] — this session's own events (Connect dispatches, user commands)
    // are live-delivered and must not be redelivered.
    let projectionCatchup = BackendState.getSqliteDb()->Option.map(db => (
      db,
      ProjectionCheckpoint.maxPosition(db, ProjectionPending.Aggregate),
      ProjectionCheckpoint.maxPosition(db, ProjectionPending.Dcb),
    ))
    // Postgres: read models are in-memory (rebuilt on every start), so capture the
    // pre-session head NOW — before plugins build or this session appends — and
    // full-replay (0, head] after the plugins register their projection handlers.
    let pgProjectionCatchup =
      BackendState.getPostgresPool()->Option.map(pool => (pool, PgProjectionCatchup.captureBounds(pool)))

    // Create scheduler and populate platform context refs.
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: ()->Obj.magic})
    hooks.apiRole := Some({val: ()->Obj.magic})

    let admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[module(LocalPluginAggregate)],
      ~readModels=[module(PluginsReadModel)],
      ~scheduler,
      ~resourceNaming=LocalPluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~stateChangeSlices=[module(UiFragmentRegistrySlice)],
      ~stateViewSlices=[module(UiFragmentsViewSlice)],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )

    // Share admin extension points with Plugin_Builder via the hooks ref.
    hooks.adminExtensionPoints :=
      admin.extensionPointsOutputs->Pulumi.Output.apply(eps =>
        eps->Array.map(ep => (ep.name, ep))->Dict.fromArray
      )

    // Intercept onPluginBuiltHook to collect per-plugin metadata synchronously.
    // The hook fires inside Component.make (synchronous) so we get a complete
    // list before the async Output.apply callbacks run.
    // We chain the existing hook (SdkService registration) so it still fires.
    let environment = Pulumi.Pulumi.getStackName()
    let existingBuiltHook = ReventlessCore.Plugin_Helpers.onPluginBuiltHook.contents
    let builtInfos: ref<array<ReventlessCore.Plugin_Helpers.pluginBuiltInfo>> = ref([])
    ReventlessCore.Plugin_Helpers.registerOnPluginBuilt(info => {
      existingBuiltHook->Option.forEach(h => h(info))
      builtInfos.contents->Array.push(info)
    })

    // Build each plugin inside its own DomainGraphQL_Server scope so its
    // GraphQL registrations form a standalone subgraph (plugin=subgraph,
    // platform=merge — mirrors the AWS source-API model).
    let plugins = plugins->Array.map(plugin => {
      module P = unpack(plugin)
      buildPluginInScope(~makePlugin=P.make, ~builtInfos)
    })

    // Restore original hook and fire deployed hooks synchronously.
    // receiveRegistry entries are pre-populated (queuing forwarder) so calls
    // are parked and drained once bindReceive fires (async, via Output.apply).
    ReventlessCore.Plugin_Helpers.onPluginBuiltHook.contents = existingBuiltHook
    let allPluginOutputs = plugins->Array.map(p =>
      (ReventlessCore.Component.outputs(p): ReventlessInfra.Plugin.outputs)
    )
    firePluginDeployedHooks(~builtInfos=builtInfos.contents, ~pluginOutputs=allPluginOutputs)

    // Wire cross-plugin Extension → EP EventTopic subscriptions.
    // Each plugin's Extension lists an extensionPointName; the matching EP EventTopic bus key
    // is derived deterministically. Bus.subscribeEventCollectorToTopic defers if the
    // EventCollector handler hasn't resolved yet (it fires after ~2 microtask ticks).
    plugins->Array.forEach(plugin => {
      let outputs: ReventlessInfra.Plugin.outputs = plugin->ReventlessCore.Component.outputs
      let _ =
        (outputs.eventCollector, outputs.extensions)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((eventCollector, extensions)) => {
          extensions->Dict.toArray->Array.forEach(((_, ext: ReventlessInfra.Extension.outputs)) => {
            let epTopicKey =
              ext.extensionPointName->String.replace(".", "") ++ "ExtPointEventTopic"
            Bus.subscribeEventCollectorToTopic(eventCollector.name, epTopicKey)
          })
        })
    })
    ReventlessCore.Plugin_Helpers.firePlatformDeployedHook({
      name: "local",
      environment,
      region: "local",
      domainApiEndpoint: "http://localhost:4000/graphql",
      domainApiRoleArn: "local",
      platformApiEndpoint: "http://localhost:4000/graphql",
      platformApiRoleArn: "local",
      adminResources: [],
    })

    // Subscribe to the Plugin aggregate event topic (Source-C live-update emission)
    // BEFORE dispatching Connect — LocalBus drops events with no subscribers.
    subscribeToPluginEvents()
    // Drive the admin Plugin read models via synthetic Connect dispatch through
    // LocalPluginAggregate (replaces the old direct-write seed). The real
    // PluginsProjection folds the emitted events into the "Plugins" QueryDb store.
    //
    // Under SQLite this trio is sequenced AFTER the projection catch-up: the
    // catch-up replays PRIOR sessions' stored events (e.g. the admin plugin
    // lifecycle history) into the projections, and this session's Connect
    // events must fold on top of — never race and be overwritten by — that
    // replay. All three calls are internally fire-and-forget Output.apply
    // chains, so deferring their invocation changes no synchronous contract.
    let seedAdminStores = () => {
      connectPlugin(~pluginComponents=plugins)
      seedPluginStructuresStore(~pluginComponents=plugins)
    }
    // Not inside `seedAdminStores`: the bake describes what this deployment
    // offers, which is settled at composition and owes nothing to projection
    // catch-up. Every plugin passed to this call is connected by construction
    // locally, so there is no status or version dedup to apply.
    //
    // The config.json overlay is written first and synchronously: it depends on
    // the *declaration* only, where the bake has to wait for every plugin's
    // structure Output to land. Unconditional, unlike the bake, because it is
    // also what restores the shipped file for a platform that has stopped
    // declaring anything.
    ShellConfig.emit(
      ~bakedManifest=hostUiBundle->Option.flatMap(cfg => cfg.bakedManifest),
      ~shellConfig=hostUiBundle->Option.flatMap(cfg => cfg.shellConfig),
    )
    // Unconditional for the same reason, and one file over: it is also what
    // restores the shell package's own hints for a platform that has stopped
    // declaring its own.
    UiHints.emit(~uiHintsFile=hostUiBundle->Option.flatMap(cfg => cfg.uiHintsFile))
    // The dev loop for the file just written. Editing hints is presentation
    // work — you change a label, you want to see the label — and routing that
    // through a platform restart puts fifteen seconds between the two. The
    // watcher re-serves the file and says so on the events channel every shell
    // already holds, so the menu restacks where it stands.
    //
    // Returned watcher deliberately dropped: it is unref'd and lives exactly as
    // long as the process, like the servers above it, and holding it to close
    // would imply a shutdown path this platform does not have.
    let _ = UiHints.watch(
      ~uiHintsFile=hostUiBundle->Option.flatMap(cfg => cfg.uiHintsFile),
      ~onReload=LocalEvents_Server.broadcastUiHintsChanged,
    )
    switch hostUiBundle->Option.flatMap(cfg => cfg.bakedManifest) {
    | None => ()
    | Some(cfg) => bakeManifest(~pluginComponents=plugins, ~config=cfg)
    }
    switch (projectionCatchup, pgProjectionCatchup) {
    | (Some((db, upperBound, dcbUpperBound)), _) =>
      let _ =
        ProjectionCheckpoint.startupCatchup(~db, ~upperBound, ~dcbUpperBound, ~handlers=() =>
          Bus.projectionCatchupHandlers()
        )
        ->Promise.catch(e => {
          Console.error2("[Platform] projection catch-up failed:", e)
          Promise.resolve()
        })
        ->Promise.then(() => {
          seedAdminStores()
          Promise.resolve()
        })
    | (_, Some((pool, boundsPromise))) =>
      let _ =
        boundsPromise
        ->Promise.then(bounds =>
          PgProjectionCatchup.startupCatchup(~pool, ~bounds, ~handlers=() =>
            Bus.projectionCatchupHandlers()
          )
        )
        ->Promise.catch(e => {
          Console.error2("[Platform] postgres projection catch-up failed:", e)
          Promise.resolve()
        })
        ->Promise.then(() => {
          seedAdminStores()
          Promise.resolve()
        })
    | (None, None) => seedAdminStores()
    }

    // Seed the built-in admin plugin's structure so its Auto UI (Plugin list with
    // Activate/Deactivate buttons) renders alongside the user plugins. Admin.construct
    // does not flow through pluginStructure outputs, so we register the synthetic
    // structure manually.
    pluginStructuresStore.contents->Dict.set(
      ReventlessCore.Platform_Admin_Structure.pluginId,
      ReventlessCore.Platform_Admin_Structure.structure,
    )

    let pluginQueryDbName = ReventlessCore.PluginsReadModelSpec.name
    let uiFragmentQueryDbName = ReventlessCore.UiFragments.name

    // Wire the per-mutation plugin-status gate (Part 2.3 of the resolver plan).
    // Resolves at call-time so updates to Plugin RM status are reflected immediately.
    // Admin mutations (Platform_*) bypass the gate — the built-in admin plugin can't
    // be deactivated and its mutations have a separate admin-group SDL directive on
    // AWS. The first underscore-delimited segment of the mutation name is the owning
    // plugin's Spec name.
    //
    // Error codes follow the three-tier model in docs/analysis/plugin-lifecycle-tiers.md:
    //   `Disconnected` → `PluginUnavailable` (retryable; tier 1)
    //   `Inactive`     → `PluginInactive`    (admin-controlled; tier 2)
    CommandGeneratorResolvers_GraphQL.setPluginStatusGate(field => {
      let parts = field->String.split("_")
      let pluginPrefix = parts->Array.get(0)->Option.getOr("")
      if pluginPrefix === "Platform" {
        None
      } else {
        let statusByName = Dict.make()
        switch Bus.getQueryDbScan(pluginQueryDbName) {
        | Some(scanAll) =>
          scanAll()->Array.forEach(json =>
            switch json->S.convertOrThrow(ReventlessCore.PluginsReadModelSpec.stateSchema) {
            | state => statusByName->Dict.set(state.name, state.status)
            | exception _ => ()
            }
          )
        | None => ()
        }
        switch statusByName->Dict.get(pluginPrefix) {
        | Some(Connected) => None
        | Some(Disconnected) => Some(("PluginUnavailable", "plugin is disconnected"))
        | Some(Inactive) => Some(("PluginInactive", "plugin is inactive"))
        | Some(Retired) => Some(("PluginRetired", "plugin version has been retired"))
        | None => None
        }
      }
    })

    // Set deploy target to Platform for admin schema registration.
    // resolveTargetGraphQL/MCP() will return PlatformGraphQL_Server / PlatformMCP_Server
    // in split mode, or DomainGraphQL_Server / DomainMCP_Server in unified mode.
    currentDeployTarget.contents = Platform

    // Derive field names from the schema entries — single source of truth.
    let adminQueryEntry = ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(0)
    let singleQueryField = adminQueryEntry.singleFieldName
    let listQueryField = adminQueryEntry.listFieldName
    let adminMutationEntries = ReventlessCore.Platform_AdminApi.mutationEntries(~cloner=Config.cloner)
    let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)

    // Register the admin Plugin aggregate's types/queries/mutations to the platform target.
    let platformGraphQL = resolveTargetGraphQL()
    let platformMCP = resolveTargetMCP()
    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
      ReventlessCore.Platform_AdminApi.baseFragment(~cloner=Config.cloner),
    )
    platformGraphQL.registerTypes(~sdlTypes=baseParts.types)

    // Resolvers for the admin Plugin queries — backed by Bus Plugin QueryDb.
    let queryResolvers = Dict.make()
    queryResolvers->Dict.set(singleQueryField, async (_root, args, _ctx): JSON.t => {
      let id =
        args
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("id"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.getOr("")
      switch Bus.getQueryDb(pluginQueryDbName) {
      | Some(ops) =>
        let items = await ops.loadStream(id)
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
        items->Array.get(0)->Option.getOr(JSON.Encode.null)
      | None => JSON.Encode.null
      }
    })
    queryResolvers->Dict.set(listQueryField, async (_root, _args, _ctx): JSON.t => {
      let items = switch Bus.getQueryDbScan(pluginQueryDbName) {
      | Some(scanAll) => scanAll()
      | None => []
      }
      connectionResponse(items)
    })
    // Platform_ComponentDefinitions resolver — SDL is already stitched into baseParts via
    // Platform_AdminApi.baseFragment so we register only the resolver here. Encoder is shared
    // with the AWS adapter so responses are byte-identical.
    //
    // Filter by plugin lifecycle status to mirror the AWS DynamoDB filter in
    // Platform_ComponentDefinitions_Lambda.res (`contains(#status, :connected)`). Plugins
    // whose Plugin RM row is not Connected are hidden until reactivated. The built-in
    // Platform_Admin entry has no Plugin RM row — include it unconditionally since
    // it can't be deactivated.
    // The plugins both structure queries answer over: one entry per plugin name,
    // Connected only, highest version. Shared so the two fields can never disagree
    // about which plugins exist — mirrors the single Lambda serving both fields on
    // the AWS side.
    let connectedLatestStructures = () => {
      let pluginStatusById = {
        let dict = Dict.make()
        switch Bus.getQueryDbScan(pluginQueryDbName) {
        | Some(scanAll) =>
          scanAll()->Array.forEach(json =>
            switch json->S.convertOrThrow(ReventlessCore.PluginsReadModelSpec.stateSchema) {
            | state =>
              let id = state.name ++ "@" ++ state.version
              dict->Dict.set(id, state.status)
            | exception _ => ()
            }
          )
        | None => ()
        }
        dict
      }
      let adminPluginId = ReventlessCore.Platform_Admin_Structure.pluginId
      // One entry per plugin name: among Connected versions keep the highest
      // version, enforcing the deploy-time one-version-per-plugin invariant.
      // Without this, a lingering Connected older version (rolling deploy or a
      // missed retire) surfaces a full duplicate set of AutoUI menu entries —
      // mirrors the dedup in Platform_ComponentDefinitions_Lambda.res.
      let latestByName = Dict.make()
      pluginStructuresStore.contents
      ->Dict.toArray
      ->Array.forEach(((pluginId, def)) => {
        let connected =
          pluginId === adminPluginId ||
            switch pluginStatusById->Dict.get(pluginId) {
            | Some(Connected) => true
            | _ => false
            }
        if connected {
          let name = ReventlessCore.Plugin.name(pluginId)
          let version = ReventlessCore.Plugin.version(pluginId)
          switch latestByName->Dict.get(name) {
          | Some((prevVersion, _)) =>
            if ReventlessCore.Plugin.compareVersions(version, prevVersion) > 0 {
              latestByName->Dict.set(name, (version, (pluginId, def)))
            }
          | None => latestByName->Dict.set(name, (version, (pluginId, def)))
          }
        }
      })
      latestByName->Dict.valuesToArray->Array.map(((_, pair)) => pair)
    }

    queryResolvers->Dict.set(
      "Platform_ComponentDefinitions",
      async (_root, _args, _ctx): JSON.t =>
        connectedLatestStructures()
        ->Array.map(((pluginId, def)) =>
          ReventlessCore.Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId, def)
        )
        ->JSON.Encode.array,
    )

    // Platform_PluginStructures resolver — the same plugins, encoded unfiltered for
    // developer tooling (Internal components kept, extension points carried).
    queryResolvers->Dict.set(
      "Platform_PluginStructures",
      async (_root, _args, _ctx): JSON.t =>
        connectedLatestStructures()
        ->Array.map(((pluginId, def)) =>
          ReventlessCore.Platform_PluginStructuresApi.encodePluginStructureEntry(~pluginId, def)
        )
        ->JSON.Encode.array,
    )

    // Platform_UIFragments resolver — reads the UiFragments StateViewSlice
    // QueryDb (populated by the UiFragmentRegistry slice's projection) and
    // encodes via the shared Platform_UIFragmentsApi encoder so AWS and
    // in-memory return the same JSON shape.
    queryResolvers->Dict.set(
      "Platform_UIFragments",
      async (_root, _args, _ctx): JSON.t => {
        let items = switch Bus.getQueryDbScan(uiFragmentQueryDbName) {
        | Some(scanAll) => scanAll()
        | None => []
        }
        // Collapse to one entry per plugin name (highest version). The registry is
        // keyed by bare plugin name now (a no-op collapse), but rows persisted by
        // the pre-slice registry were keyed name@version — keep the dedup so a
        // mixed store never surfaces duplicates (mirrors Platform_UIFragments_Lambda.res).
        let latestByName = Dict.make()
        items->Array.forEach(item =>
          switch item->S.parseOrThrow(ReventlessCore.UiFragments.stateSchema) {
          | state =>
            let name = ReventlessCore.Plugin.name(state.pluginId)
            let version = ReventlessCore.Plugin.version(state.pluginId)
            switch latestByName->Dict.get(name) {
            | Some((prevVersion, _)) =>
              if ReventlessCore.Plugin.compareVersions(version, prevVersion) > 0 {
                latestByName->Dict.set(name, (version, state))
              }
            | None => latestByName->Dict.set(name, (version, state))
            }
          | exception _ => ()
          }
        )
        latestByName
        ->Dict.valuesToArray
        ->Array.map(((_, state)) =>
          ReventlessCore.Platform_UIFragmentsApi.encodeUIFragmentEntry(state)
        )
        ->JSON.Encode.array
      },
    )
    // Composite-key / index admin query fields. Live loads from the seeded QueryDb stores.
    registerAdminItemsAndIndexResolvers(~queryResolvers, ~live=true)

    platformGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    // Admin Plugin lifecycle mutations (Activate / Deactivate / Retire) now flow
    // through the LocalPluginAggregate, mirroring AWS. The resolver looks up the
    // plugin's current version from the "Plugins" read model (the aggregate is
    // name-keyed but Activate/Deactivate/Retire target a specific version), then
    // dispatches the matching command. The aggregate emits VersionActivated /
    // VersionDeactivated / VersionRetired; PluginsProjection folds the new status
    // into the store and subscribeToPluginEvents fans onPluginStatusChange out to
    // live subscribers — so no direct QueryDb write or inline publish here.
    let argId = (args: JSON.t) =>
      args
      ->JSON.Decode.object
      ->Option.flatMap(d => d->Dict.get("id"))
      ->Option.flatMap(JSON.Decode.string)
      ->Option.getOr("")
    // Resolve the plugin's current version from its Plugins read-model row.
    let currentVersionOf = (pluginName: string): option<string> =>
      switch Bus.getQueryDbScan(pluginQueryDbName) {
      | Some(scanAll) =>
        scanAll()->Array.findMap(json =>
          switch json->S.convertOrThrow(ReventlessCore.PluginsReadModelSpec.stateSchema) {
          | state if state.name == pluginName => Some(state.version)
          | _ => None
          | exception _ => None
          }
        )
      | None => None
      }
    // The admin Plugin lifecycle SDL is `<field>(id: ID!, _0: String!)` — `id` is the
    // plugin name (aggregate id) and `_0` is the target version (the command payload,
    // e.g. `Activate(version)`). Use the caller-supplied `_0` when present; fall back
    // to the plugin's current version from the Plugins read model for callers that
    // omit it.
    let argVersion = (args: JSON.t) =>
      args
      ->JSON.Decode.object
      ->Option.flatMap(d => d->Dict.get("_0"))
      ->Option.flatMap(JSON.Decode.string)
    let dispatchLifecycle = (
      ~field: string,
      args: JSON.t,
      makeCommand: string => ReventlessCore.PluginSpec.command,
    ): JSON.t => {
      let msgId = ReventlessCore.Message.uuid()
      let pluginName = argId(args)
      let version = switch argVersion(args) {
      | Some(v) if v != "" => Some(v)
      | _ => currentVersionOf(pluginName)
      }
      switch version {
      | Some(version) =>
        log.info(~comp=ReventlessCore.Platform_Admin_Structure.pluginId, `${field}(${pluginName}@${version}): dispatching to aggregate`)
        let _ = dispatchPluginCommand(~pluginName, ~command=makeCommand(version))
      | None => log.warn(~comp=ReventlessCore.Platform_Admin_Structure.pluginId, `${field}(${pluginName}): plugin not found`)
      }
      commandAccepted(~msgId, ~entityId=pluginName)
    }
    let activateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Activate")
    let deactivateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Deactivate")
    let retireField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Retire")
    let mutationResolvers = Dict.make()
    mutationResolvers->Dict.set(activateField, async (_root, args, _ctx): JSON.t =>
      dispatchLifecycle(~field=activateField, args, v => ReventlessCore.PluginSpec.Activate(v))
    )
    mutationResolvers->Dict.set(deactivateField, async (_root, args, _ctx): JSON.t =>
      dispatchLifecycle(~field=deactivateField, args, v => ReventlessCore.PluginSpec.Deactivate(v))
    )
    mutationResolvers->Dict.set(retireField, async (_root, args, _ctx): JSON.t =>
      dispatchLifecycle(~field=retireField, args, v => ReventlessCore.PluginSpec.Retire(v))
    )
    // Remaining admin mutations (e.g., Clone) are no-ops in-memory.
    adminMutationFieldNames->Array.forEach(field =>
      if mutationResolvers->Dict.get(field)->Option.isNone {
        mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t =>
          commandAccepted(~msgId=ReventlessCore.Message.uuid())
        )
      }
    )
    // UIFragment admin mutations — explicit admin-triggered fragment changes still
    // publish onUIFragmentChange directly (slice-driven fragment changes are
    // emitted by subscribeToPluginEvents' admin-DCB subscription). uiFragmentSubTopic
    // is the shared topic.
    let makeUIEvent = (~pluginId, ~changeKind, ~manifest) =>
      JSON.Encode.object(
        Dict.fromArray([
          ("pluginId", JSON.Encode.string(ReventlessCore.Plugin.name(pluginId))),
          ("changeKind", JSON.Encode.string(changeKind)),
          ("manifest", manifest),
        ])
      )
    let addUIFragmentMutation = (fieldName, changeKind) =>
      mutationResolvers->Dict.set(fieldName, async (_root, args, _ctx): JSON.t => {
        let obj = args->JSON.Decode.object->Option.getOr(Dict.make())
        let pluginId =
          obj->Dict.get("pluginId")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
        let manifest = obj->Dict.get("manifest")->Option.getOr(JSON.Encode.null)
        let event = makeUIEvent(~pluginId, ~changeKind, ~manifest)
        LocalGraphQL_SubscriptionResolvers.publish(uiFragmentSubTopic, event)
        event
      })
    addUIFragmentMutation(
      ReventlessCore.Api_Naming.adminField(~name="UIFragmentRegistered"),
      "Registered",
    )
    addUIFragmentMutation(
      ReventlessCore.Api_Naming.adminField(~name="UIFragmentUpdated"),
      "Updated",
    )
    addUIFragmentMutation(
      ReventlessCore.Api_Naming.adminField(~name="UIFragmentDeregistered"),
      "Deregistered",
    )
    CommandGeneratorResolvers_GraphQL.ensureCommandResultTypes(platformGraphQL)
    platformGraphQL.registerMutations(
      ~sdlFields=adminMutationSdl(baseParts.mutations),
      ~resolvers=mutationResolvers,
    )
    adminRegisteredServers.contents->Array.push(platformGraphQL)
    // Register onUIFragmentChange + onPluginStatusChange subscriptions (Source C).
    // The SDL field constants are provider-neutral, shared with the AWS path.
    platformGraphQL.registerSubscriptions(
      ~sdlFields=[
        ReventlessCore.Platform_AdminApi.uiFragmentSubscriptionField,
        ReventlessCore.Platform_AdminApi.pluginStatusSubscriptionField,
      ],
      ~resolvers=Dict.fromArray([
        (
          "onUIFragmentChange",
          LocalGraphQL_SubscriptionResolvers.makeFieldResolver(uiFragmentSubTopic),
        ),
        (
          "onPluginStatusChange",
          LocalGraphQL_SubscriptionResolvers.makeFieldResolver(pluginStatusSubTopic),
        ),
      ]),
    )

    // Register admin queries and mutations as MCP resources and tools.
    // Route by field name: Plugin → pluginQueryDbName. UIFragments has its
    // own explicit `Platform_UIFragments` flat-array resolver registered
    // above; it isn't exposed as an MCP resource because the auto-generated
    // single/list field shape was removed when the auto-generated query
    // entry was dropped in favour of that explicit field.
    let adminFieldToQueryDb = Dict.fromArray([
      (singleQueryField, pluginQueryDbName),
      (listQueryField, pluginQueryDbName),
    ])
    platformMCP.registerResourcesFromEntries(
      ~pluginName=ReventlessCore.Platform_Admin_Structure.pluginId,
      ~queryEntries=ReventlessCore.PluginBaseFragment.queryEntries,
      ~queryHandler=async (resourceName, uri) => {
        let segments = uri->String.split("/")
        let id = segments->Array.at(-1)->Option.getOr("")
        let queryDbName =
          adminFieldToQueryDb->Dict.get(resourceName)->Option.getOr(pluginQueryDbName)
        switch Bus.getQueryDb(queryDbName) {
        | Some(ops) =>
          if id->String.length > 0 && id != resourceName {
            let items = await ops.loadStream(id)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
            items->Array.get(0)->Option.getOr(JSON.Encode.null)
          } else {
            switch Bus.getQueryDbScan(queryDbName) {
            | Some(scanAll) => scanAll()->JSON.Encode.array
            | None => []->JSON.Encode.array
            }
          }
        | None => JSON.Encode.null
        }
      },
    )

    // Register admin mutations as MCP tools using the same entry-based path as plugins.
    platformMCP.registerToolsFromEntries(
      ~pluginName=ReventlessCore.Platform_Admin_Structure.pluginId,
      ~mutationEntries=adminMutationEntries,
      ~commandHandler=async (toolName, args, _identity) => {
        switch platformGraphQL.getMutationResolver(toolName) {
        | Some(resolver) =>
          let result = await resolver(JSON.Encode.null, args, JSON.Encode.null)
          switch result->JSON.Decode.string {
          | Some(s) => s
          | None => result->JSON.stringify
          }
        | None => `error: no handler found for tool ${toolName}`
        }
      },
    )

    // Always inject Relay base types (Node interface, PageInfo) and the node
    // query field into the domain GraphQL server so that:
    // 1. `type X implements Node { ... }` fragments compile (Node interface must exist)
    // 2. The node resolver registered by QueryDbResolvers_GraphQL.res has a
    //    matching `node(id: ID!): Node` field in the Query type.
    DomainGraphQL_Server.registerTypes(~sdlTypes=ReventlessCore.GraphQL_Stitcher.relayBaseTypes)
    DomainGraphQL_Server.registerQueries(
      ~sdlFields=ReventlessCore.GraphQL_Stitcher.relayBaseQueries,
      ~resolvers=Dict.make(),
    )
    // Upload service (route B) on the domain server — mirrors adding it to
    // `domainBaseFragment` on AWS.
    LocalUploadResolvers.register(DomainGraphQL_Server.asInterface)
    // Geocoding client door (D9 half 2) on the domain server — same mirror. A dev
    // stub (no real geocoder locally), so the map picker's search box works offline.
    LocalGeocodeResolvers.register(DomainGraphQL_Server.asInterface)
    // In split mode, inject Relay base types (Node interface, PageInfo) into the platform
    // server so SDL fragments compile. The node(id) query is Domain-only — the Platform
    // API is consumed by admin tools and agents, not Relay clients.
    if Config.splitApi {
      PlatformGraphQL_Server.registerTypes(~sdlTypes=ReventlessCore.GraphQL_Stitcher.relayBaseTypes)
    }

    // Reset deploy target to Domain after admin registration is done.
    currentDeployTarget.contents = Domain

    // In split mode, start() is deferred to startServers() so all plugins
    // (domain and platform) can register their schema first.
    // In unified mode, start immediately (backwards-compatible).
    if !Config.splitApi {
      UserStore.autoLoadOnce()
      DomainGraphQL_Server.start()
      DomainMCP_Server.start()
    }

  }

  let deployPlatform = (
    ~version,
    ~hostUiBundle as _: option<hostUiBundleConfig>=?,
    // Declared stores are provisioned infrastructure; the in-memory platform
    // provisions none and serves uploads from the dev server, so the list is
    // carried to satisfy the shared Platform.T signature and ignored.
    ~capabilities as _: array<ReventlessInfra.Platform.capability>=[],
  ) => {
    log.info(~comp="Platform", `deployPlatform v${version}`)
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: ()->Obj.magic})
    hooks.apiRole := Some({val: ()->Obj.magic})
    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=LocalPluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~stateChangeSlices=[module(UiFragmentRegistrySlice)],
      ~stateViewSlices=[module(UiFragmentsViewSlice)],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )

    // Route admin schema to PlatformGraphQL_Server in split mode, DomainGraphQL_Server otherwise.
    currentDeployTarget.contents = Platform
    let adminGraphQL = resolveTargetGraphQL()
    let adminMCP = resolveTargetMCP()

    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
      ReventlessCore.Platform_AdminApi.baseFragment(~cloner=Config.cloner),
    )
    adminGraphQL.registerTypes(~sdlTypes=baseParts.types)

    // Minimal admin query resolvers (no plugin QueryDb seeding needed for platform-only).
    let queryResolvers = Dict.make()
    let adminQueryEntry = ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(0)
    queryResolvers->Dict.set(adminQueryEntry.singleFieldName, async (_root, _args, _ctx): JSON.t =>
      JSON.Encode.null
    )
    queryResolvers->Dict.set(adminQueryEntry.listFieldName, async (_root, _args, _ctx): JSON.t =>
      connectionResponse([])
    )
    // Platform_UIFragments — empty in the platform-only path (no plugins
    // connected → no UI fragments registered). The SDL declares it as a
    // non-null array so we must register a resolver returning [].
    queryResolvers->Dict.set(
      "Platform_UIFragments",
      async (_root, _args, _ctx): JSON.t => JSON.Encode.array([]),
    )
    // Composite-key / index admin query fields — empty stubs in the platform-only
    // path (no plugins connected → no QueryDb seeded).
    registerAdminItemsAndIndexResolvers(~queryResolvers, ~live=false)
    adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    let mutationResolvers = Dict.make()
    let adminMutationEntries = ReventlessCore.Platform_AdminApi.mutationEntries(~cloner=Config.cloner)
    let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)
    adminMutationFieldNames->Array.forEach(field =>
      mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t =>
        commandAccepted(~msgId=ReventlessCore.Message.uuid())
      )
    )
    let dpSubTopic = "onUIFragmentChange"
    let addUIFragmentMutation2 = (fieldName, changeKind) =>
      mutationResolvers->Dict.set(fieldName, async (_root, args, _ctx): JSON.t => {
        let obj = args->JSON.Decode.object->Option.getOr(Dict.make())
        let pluginId =
          obj->Dict.get("pluginId")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
        let manifest = obj->Dict.get("manifest")->Option.getOr(JSON.Encode.null)
        let event = JSON.Encode.object(
          Dict.fromArray([
            ("pluginId", JSON.Encode.string(ReventlessCore.Plugin.name(pluginId))),
            ("changeKind", JSON.Encode.string(changeKind)),
            ("manifest", manifest),
          ]),
        )
        LocalGraphQL_SubscriptionResolvers.publish(dpSubTopic, event)
        event
      })
    addUIFragmentMutation2(
      ReventlessCore.Api_Naming.adminField(~name="UIFragmentRegistered"),
      "Registered",
    )
    addUIFragmentMutation2(
      ReventlessCore.Api_Naming.adminField(~name="UIFragmentUpdated"),
      "Updated",
    )
    addUIFragmentMutation2(
      ReventlessCore.Api_Naming.adminField(~name="UIFragmentDeregistered"),
      "Deregistered",
    )
    CommandGeneratorResolvers_GraphQL.ensureCommandResultTypes(adminGraphQL)
    adminGraphQL.registerMutations(~sdlFields=adminMutationSdl(baseParts.mutations), ~resolvers=mutationResolvers)
    adminGraphQL.registerSubscriptions(
      ~sdlFields=[
        "  onUIFragmentChange: UIFragmentChangeEvent",
        "  onPluginStatusChange: PluginStatusChangeEvent",
      ],
      ~resolvers=Dict.fromArray([
        (
          "onUIFragmentChange",
          LocalGraphQL_SubscriptionResolvers.makeFieldResolver(dpSubTopic),
        ),
        (
          "onPluginStatusChange",
          LocalGraphQL_SubscriptionResolvers.makeFieldResolver("onPluginStatusChange"),
        ),
      ]),
    )

    currentDeployTarget.contents = Domain

    // Start servers immediately (deployPlatform is always called standalone).
    // Wire `Auth_GraphqlContext.buildAuthContext` so the admin yoga server
    // extracts identity from the bearer token, same as the Domain server.
    // Without this, Platform_* queries / mutations run as `anonymous` and
    // skip the group authorization that AppSync would enforce via
    // `@aws_cognito_user_pools(cognito_groups: ["Admin"])` in production. The Domain
    // server's `asInterface.start` accepts but ignores `~contextFactory`
    // because it always wires its own internal auth context.
    adminGraphQL.start(
      ~port=if Config.splitApi { 4001 } else { 4000 },
      ~contextFactory=Auth_GraphqlContext.buildAuthContext,
      (),
    )
    adminMCP.start(~port=if Config.splitApi { 3002 } else { 3001 }, ())
    if Config.splitApi {
      DomainGraphQL_Server.start()
      DomainMCP_Server.start()
    }

    // Fire onPlatformDeployed hook with local platform metadata.
    ReventlessCore.Plugin_Helpers.firePlatformDeployedHook({
      name: "local",
      environment: "local",
      region: "local",
      domainApiEndpoint: "http://localhost:4000/graphql",
      domainApiRoleArn: "local",
      platformApiEndpoint: if Config.splitApi {
        "http://localhost:4001/graphql"
      } else {
        "http://localhost:4000/graphql"
      },
      platformApiRoleArn: "local",
      adminResources: [],
    })
    Dict.make()
  }

  let deployPlugin = (~plugin: module(PluginMaker), ~apiTarget=Domain) => {
    log.info(~comp="Platform", `deployPlugin target=${switch apiTarget { | Domain => "Domain" | Platform => "Platform" }}`)

    // Set the active deploy target so resolveTargetGraphQL/MCP() and QueryDb serverRef/relayRef
    // route registrations to the correct server. Mirrors AWS resolveTargetApi() pattern.
    currentDeployTarget.contents = apiTarget
    // Update QueryDb server/relay refs on the shared StateViewSliceMaker.QueryDbResolvers instance.
    // Do NOT create a new QueryDbResolvers_GraphQL.Make(Bus) here — that would be a different
    // module instance from the one StateViewSlice_Builder captured, leaving its refs unchanged.
    StateViewSliceMaker.QueryDbResolvers.serverRef.contents = resolveTargetGraphQL()
    StateViewSliceMaker.QueryDbResolvers.relayRef.contents = switch apiTarget {
    | Domain => Some(domainRelaySupport)
    | Platform => None
    }

    // Each plugin creates its own scheduler (mirrors AWS behaviour).
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: ()->Obj.magic})
    hooks.apiRole := Some({val: ()->Obj.magic})

    // Admin components are needed in-memory even for single-plugin deploy.
    // Admin.construct ignores ~version (it's `~version as _` in Platform_Admin)
    // so the empty placeholder doesn't affect behavior.
    let admin = Admin.construct(
      ~version="",
      ~extensionPoints=[],
      ~aggregates=[module(LocalPluginAggregate)],
      ~readModels=[module(PluginsReadModel)],
      ~scheduler,
      ~resourceNaming=LocalPluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~stateChangeSlices=[module(UiFragmentRegistrySlice)],
      ~stateViewSlices=[module(UiFragmentsViewSlice)],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )
    hooks.adminExtensionPoints :=
      admin.extensionPointsOutputs->Pulumi.Output.apply(eps =>
        eps->Array.map(ep => (ep.name, ep))->Dict.fromArray
      )

    // Intercept onPluginBuiltHook so we can fire onPluginDeployed after build.
    let existingBuiltHook = ReventlessCore.Plugin_Helpers.onPluginBuiltHook.contents
    let builtInfos: ref<array<ReventlessCore.Plugin_Helpers.pluginBuiltInfo>> = ref([])
    ReventlessCore.Plugin_Helpers.registerOnPluginBuilt(info => {
      existingBuiltHook->Option.forEach(h => h(info))
      builtInfos.contents->Array.push(info)
    })

    // Construct the plugin inside its own DomainGraphQL_Server scope
    // (plugin=subgraph — see buildPluginInScope). Registrations targeting the
    // platform server (apiTarget=Platform in split mode) are unaffected:
    // scopes only exist on DomainGraphQL_Server.
    module P = unpack(plugin)
    let pluginComponent = buildPluginInScope(~makePlugin=P.make, ~builtInfos)

    ReventlessCore.Plugin_Helpers.onPluginBuiltHook.contents = existingBuiltHook

    // Register admin schema to the correct target (domain or platform).
    // Skip if already registered by makePlatform (both target the same server).
    let adminGraphQL = resolveTargetGraphQL()
    if !(adminRegisteredServers.contents->Array.some(s => s === adminGraphQL)) {
      let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
        ReventlessCore.Platform_AdminApi.baseFragment(~cloner=Config.cloner),
      )
      adminGraphQL.registerTypes(~sdlTypes=baseParts.types)

      let queryResolvers = Dict.make()
      let adminQueryEntry = ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(0)
      queryResolvers->Dict.set(adminQueryEntry.singleFieldName, async (_root, _args, _ctx): JSON.t =>
        JSON.Encode.null
      )
      queryResolvers->Dict.set(adminQueryEntry.listFieldName, async (_root, _args, _ctx): JSON.t =>
        connectionResponse([])
      )
      // Platform_UIFragments — single-plugin path. Populated by the
      // UiFragments StateViewSlice when the plugin registers a manifest through
      // the admin EP (connectPlugin below), otherwise scans an empty store.
      queryResolvers->Dict.set(
        "Platform_UIFragments",
        async (_root, _args, _ctx): JSON.t => {
          let items = switch Bus.getQueryDbScan(ReventlessCore.UiFragments.name) {
          | Some(scanAll) => scanAll()
          | None => []
          }
          items
          ->Array.filterMap(item =>
            switch item->S.parseOrThrow(ReventlessCore.UiFragments.stateSchema) {
            | state =>
              Some(ReventlessCore.Platform_UIFragmentsApi.encodeUIFragmentEntry(state))
            | exception _ => None
            }
          )
          ->JSON.Encode.array
        },
      )
      // Platform_ComponentDefinitions resolver — SDL is already stitched into baseParts via
      // Platform_AdminApi.baseFragment so we register only the resolver here. Uses the shared
      // encoder so the dynamic-plugin admin server emits the same canonical shape as
      // the main platform server (and as AWS).
      queryResolvers->Dict.set(
        "Platform_ComponentDefinitions",
        async (_root, _args, _ctx): JSON.t =>
          pluginStructuresStore.contents
          ->Dict.toArray
          ->Array.map(((pluginId, def)) =>
            ReventlessCore.Platform_ComponentDefinitionsApi.encodePluginStructureEntry(~pluginId, def)
          )
          ->JSON.Encode.array,
      )
      // Composite-key / index admin query fields.
      // Live loads from the seeded QueryDb stores (empty when not yet seeded).
      registerAdminItemsAndIndexResolvers(~queryResolvers, ~live=true)
      adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

      let mutationResolvers = Dict.make()
      let adminMutationEntries = ReventlessCore.Platform_AdminApi.mutationEntries(~cloner=Config.cloner)
      let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)
      adminMutationFieldNames->Array.forEach(field =>
        mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t =>
          commandAccepted(~msgId=ReventlessCore.Message.uuid())
        )
      )
      let dpSubTopic2 = "onUIFragmentChange"
      let addUIFragmentMutation3 = (fieldName, changeKind) =>
        mutationResolvers->Dict.set(fieldName, async (_root, args, _ctx): JSON.t => {
          let obj = args->JSON.Decode.object->Option.getOr(Dict.make())
          let pluginId =
            obj->Dict.get("pluginId")->Option.flatMap(JSON.Decode.string)->Option.getOr("")
          let manifest = obj->Dict.get("manifest")->Option.getOr(JSON.Encode.null)
          let event = JSON.Encode.object(
            Dict.fromArray([
              ("pluginId", JSON.Encode.string(ReventlessCore.Plugin.name(pluginId))),
              ("changeKind", JSON.Encode.string(changeKind)),
              ("manifest", manifest),
            ]),
          )
          LocalGraphQL_SubscriptionResolvers.publish(dpSubTopic2, event)
          event
        })
      addUIFragmentMutation3(
        ReventlessCore.Api_Naming.adminField(~name="UIFragmentRegistered"),
        "Registered",
      )
      addUIFragmentMutation3(
        ReventlessCore.Api_Naming.adminField(~name="UIFragmentUpdated"),
        "Updated",
      )
      addUIFragmentMutation3(
        ReventlessCore.Api_Naming.adminField(~name="UIFragmentDeregistered"),
        "Deregistered",
      )
      CommandGeneratorResolvers_GraphQL.ensureCommandResultTypes(adminGraphQL)
      adminGraphQL.registerMutations(~sdlFields=adminMutationSdl(baseParts.mutations), ~resolvers=mutationResolvers)
      adminGraphQL.registerSubscriptions(
        ~sdlFields=["  onUIFragmentChange: UIFragmentChangeEvent"],
        ~resolvers=Dict.fromArray([
          (
            "onUIFragmentChange",
            LocalGraphQL_SubscriptionResolvers.makeFieldResolver(dpSubTopic2),
          ),
        ]),
      )
      adminRegisteredServers.contents->Array.push(adminGraphQL)
    }

    // Reset deploy target back to Domain for subsequent calls.
    currentDeployTarget.contents = Domain
    StateViewSliceMaker.QueryDbResolvers.serverRef.contents = DomainGraphQL_Server.asInterface
    StateViewSliceMaker.QueryDbResolvers.relayRef.contents = Some(domainRelaySupport)

    // Subscribe to the Plugin aggregate event topic before dispatching Connect.
    subscribeToPluginEvents()
    // Drive the admin Plugin read models via synthetic Connect dispatch through
    // LocalPluginAggregate (replaces the old direct-write seed).
    connectPlugin(~pluginComponents=[pluginComponent])
    seedPluginStructuresStore(~pluginComponents=[pluginComponent])

    // Fire onPluginDeployed hooks so subscribers learn about this plugin.
    let deployedPluginOutputs = [(ReventlessCore.Component.outputs(pluginComponent): ReventlessInfra.Plugin.outputs)]
    firePluginDeployedHooks(~builtInfos=builtInfos.contents, ~pluginOutputs=deployedPluginOutputs)

    // Late-deployed plugins may register an onPlatformDeployed hook that missed
    // the original firing in makePlatform. Replay the stored info so they
    // receive the platform metadata they need.
    ReventlessCore.Plugin_Helpers.replayPlatformDeployedHook()

    // In unified mode, start servers immediately (backwards-compatible).
    // In split mode, start() is deferred to startServers().
    if !Config.splitApi {
      switch apiTarget {
      | Domain =>
        DomainGraphQL_Server.start()
        DomainMCP_Server.start()
      | Platform =>
        PlatformGraphQL_Server.start(
          ~port=4001,
          ~contextFactory=Auth_GraphqlContext.buildAuthContext,
          (),
        )
        PlatformMCP_Server.start(~port=3002, ())
      }
    }

    Dict.make()
  }
}

// Default platform — diagnostic warnings enabled, split API (admin on separate ports), no cloner.
// Backend defaults to Memory unless REVENTLESS_LOCAL_BACKEND is set.
module Make = (): (ReventlessInfra.Platform.T with type api = unit and type role = unit) => {
  include MakeWithConfig({
    let silent = false
    let splitApi = true
    let cloner = false
    let backend = Backend.fromEnv()
    let commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs = {}
  })
}
