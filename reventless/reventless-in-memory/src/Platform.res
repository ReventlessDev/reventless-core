// In-memory Platform — implements ReventlessInfra.Platform.T using only in-memory data structures.
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

let log = ReventlessCore.Logger.fromEnv()

// Module-level ref to hold the platform GraphQL server instance in split mode.
// Populated by makePlatform when splitApi=true.
let platformGraphQLRef: ref<option<GraphQL_ServerInstance.t>> = ref(None)
let getPlatformGraphQL = () => platformGraphQLRef.contents

// Module-level ref to hold the platform MCP server instance in split mode.
// Populated by makePlatform when splitApi=true.
let platformMCPRef: ref<option<MCP_ServerInstance.t>> = ref(None)

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
  // in-memory platform has no per-component process boundary.
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
  | Backend.Sqlite({path, resetOnStart}) =>
    if resetOnStart {
      Backend.removeFileIfExists(path)
    }
    let db = SqliteDriver.openDb(~path)
    BackendState.setSqlite(~db, ~path)
  }

  module Bus = InMemory_Bus.Impl({
    let capacity = None
    let silent = Config.silent
  })

  // Track which API target is active during deployPlugin / admin schema registration.
  // Domain = plugin-facing (default); Platform = admin/core (split mode).
  let currentDeployTarget: ref<apiTarget> = ref(Domain)

  // Track which GraphQL servers have had admin schema (Plugin queries/mutations) registered.
  // Prevents double-registration when makePlatform and deployPlugin both target the same server.
  let adminRegisteredServers: ref<array<GraphQL_ServerInstance.t>> = ref([])

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
  let resolveTargetGraphQL = (): GraphQL_ServerInstance.t =>
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
            let filtered = switch after {
            | Some(afterPos) =>
              let idx =
                events->Array.findIndex(e => getPosition(e)->Option.mapOr(false, p => p > afterPos))
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
        open GraphQL_SubscriptionResolvers_InMemory
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
        let moduleUrl = Spec.moduleUrl
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
        let moduleUrl = Spec.moduleUrl
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
        let moduleUrl = Spec.moduleUrl
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

  // Empty base fragment — no types, no mutations, no queries.
  // Used by the plugin Api in split mode so plugin schema has no core fields.
  let emptyBaseFragment = ReventlessCore.GraphQL_Stitcher.encode({
    types: [],
    mutations: [],
    queries: [],
    subscriptions: [],
  })

  module Api = {
    module Make = (
      FragmentConfig: {
        let baseFragment: ReventlessInfra.Api.schemaFragment
      },
    ): ReventlessInfra.Api.T => {
      module Builder = ReventlessCore.Api_Builder.Make(GraphQL_InMemory_Adapter)
      // In split mode, the plugin API uses an empty base fragment so plugin schema
      // has no core fields. In unified mode, use the provided base fragment as-is.
      let effectiveBaseFragment = if Config.splitApi {
        emptyBaseFragment
      } else {
        FragmentConfig.baseFragment
      }
      let make = (~name, ~opts=?) =>
        Builder.make(~name, ~baseFragment=effectiveBaseFragment, ~opts?)
    }
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

  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module QE = QueryEngine_InMemory.Make(Bus)

  // Admin-internal Plugin aggregate. Constructed here so it can be threaded into
  // Admin.construct's ~aggregates parameter — registerAdminAggregateMutations then
  // wires Platform_Plugin_Activate / Platform_Plugin_Deactivate through the standard
  // CommandGenerator auto-flow (same path user-plugin aggregates use). Internal-protocol
  // variants (Heartbeat, Connect, Disconnect, ReportIncompatibility) carry `@noApi` and
  // are filtered out before SDL/resolver generation.
  module InMemoryPluginAggregate: ReventlessInfra.Aggregate.T with type api = unit = AggregateMaker.Make(
    ReventlessCore.PluginSpec,
    ReventlessCore.PluginBehavior,
    ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
  )

  module Admin = ReventlessCore.Platform_Admin.Make(
    RuntimeEnvironment_InMemory,
    EventCollectorChannel,
    QE,
    ClonerRunner_InMemory,
    ReventlessCore.PluginRuntime_Builder_Micro.Make(
      RuntimeEnvironment_InMemory,
      EventCollectorChannel,
    ),
    DcbEventLogStorage_InMemory.Make(Bus),
    EventTopicPublisher_InMemory.Make(Bus),
    CommandTopicChannel_InMemory.Make(Bus),
    CommandTopicChannel_InMemory.Make(Bus),
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
    module SP = ScheduledPublisher_InMemory.Make(Bus)
    module S = ReventlessCore.Scheduler_Builder.Make(SP)
    let component = S.make()
    component->ReventlessCore.Component.operations
  }

  @val external processEnv: dict<string> = "process.env"
  let graphqlDebug = processEnv->Dict.get("GRAPHQL_DEBUG")->Option.isSome

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpSupported

  // ---------------------------------------------------------------------------
  // Shared helpers — used by both makePlatform and deployPlugin.
  // ---------------------------------------------------------------------------

  // Plugin QueryDb store ops — initialized lazily on first seedPluginQueryDb call.
  let pluginQueryDbOpsRef: ref<option<ReventlessCore.QueryDb_Adapter.operations>> = ref(None)

  // Ensure the Plugin QueryDb store is registered in the Bus. Returns the ops handle.
  let ensurePluginQueryDbStore = () => {
    switch pluginQueryDbOpsRef.contents {
    | Some(ops) => ops
    | None =>
      let pluginQueryDbName = ReventlessCore.PluginsReadModelSpec.name
      let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
      let allItems: ref<array<JSON.t>> = ref([])
      let syncAll = () => {
        allItems.contents =
          store.contents
          ->Dict.toArray
          ->Array.flatMap(((id, items)) =>
            items->Array.map(item => {
              let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
              if !(obj->Dict.get("id")->Option.isSome) {
                let copy = Dict.make()
                obj->Dict.toArray->Array.forEach(((k, v)) => copy->Dict.set(k, v))
                copy->Dict.set("id", JSON.Encode.string(id))
                JSON.Encode.object(copy)
              } else {
                item
              }
            })
          )
      }
      let pluginOps: ReventlessCore.QueryDb_Adapter.operations = {
        load: async id => Ok(store.contents->Dict.get(id)->Option.getOr([])),
        loadStream: id =>
          store.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable,
        save: async (id, state, _, _) => {
          store.contents->Dict.set(id, [state])
          syncAll()
          Ok()
        },
        saveBatch: async batch => {
          batch->Array.forEach(((id, state, _)) => store.contents->Dict.set(id, [state]))
          syncAll()
          Ok()
        },
        count: async (_, _, inc) => Ok(inc),
        delete: async (id, _) => {
          store.contents->Dict.delete(id)
          syncAll()
          Ok()
        },
        deleteBatch: async ids => {
          ids->Array.forEach(((id, _)) => store.contents->Dict.delete(id))
          syncAll()
          Ok()
        },
      }
      Bus.registerQueryDb(pluginQueryDbName, pluginOps)
      Bus.registerQueryDbScan(pluginQueryDbName, () => allItems.contents)
      Bus.registerQueryDbStream(
        pluginQueryDbName,
        () => allItems.contents->Stream.fromIterable,
      )
      pluginQueryDbOpsRef := Some(pluginOps)
      pluginOps
    }
  }

  // UIFragmentRegistry QueryDb store ops — initialized lazily on first seed call.
  let uiFragmentQueryDbOpsRef: ref<option<ReventlessCore.QueryDb_Adapter.operations>> = ref(None)

  let ensureUIFragmentRegistryQueryDbStore = () => {
    switch uiFragmentQueryDbOpsRef.contents {
    | Some(ops) => ops
    | None =>
      let name = ReventlessCore.UIFragmentRegistryReadModelSpec.name
      let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
      let allItems: ref<array<JSON.t>> = ref([])
      let syncAll = () => {
        allItems.contents =
          store.contents
          ->Dict.toArray
          ->Array.flatMap(((id, items)) =>
            items->Array.map(item => {
              let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
              if !(obj->Dict.get("id")->Option.isSome) {
                let copy = Dict.make()
                obj->Dict.toArray->Array.forEach(((k, v)) => copy->Dict.set(k, v))
                copy->Dict.set("id", JSON.Encode.string(id))
                JSON.Encode.object(copy)
              } else {
                item
              }
            })
          )
      }
      let ops: ReventlessCore.QueryDb_Adapter.operations = {
        load: async id => Ok(store.contents->Dict.get(id)->Option.getOr([])),
        loadStream: id =>
          store.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable,
        save: async (id, state, _, _) => {
          store.contents->Dict.set(id, [state])
          syncAll()
          Ok()
        },
        saveBatch: async batch => {
          batch->Array.forEach(((id, state, _)) => store.contents->Dict.set(id, [state]))
          syncAll()
          Ok()
        },
        count: async (_, _, inc) => Ok(inc),
        delete: async (id, _) => {
          store.contents->Dict.delete(id)
          syncAll()
          Ok()
        },
        deleteBatch: async ids => {
          ids->Array.forEach(((id, _)) => store.contents->Dict.delete(id))
          syncAll()
          Ok()
        },
      }
      Bus.registerQueryDb(name, ops)
      Bus.registerQueryDbScan(name, () => allItems.contents)
      Bus.registerQueryDbStream(name, () => allItems.contents->Stream.fromIterable)
      uiFragmentQueryDbOpsRef := Some(ops)
      ops
    }
  }

  // PlatformEventGraph QueryDb store ops — initialized lazily on first seed call.
  let platformEventGraphQueryDbOpsRef: ref<
    option<ReventlessCore.QueryDb_Adapter.operations>,
  > = ref(None)

  let ensurePlatformEventGraphQueryDbStore = () => {
    switch platformEventGraphQueryDbOpsRef.contents {
    | Some(ops) => ops
    | None =>
      let name = ReventlessCore.Platform_EventGraphReadModelSpec.name
      let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
      let allItems: ref<array<JSON.t>> = ref([])
      let syncAll = () => {
        allItems.contents =
          store.contents
          ->Dict.toArray
          ->Array.flatMap(((id, items)) =>
            items->Array.map(item => {
              let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
              if !(obj->Dict.get("id")->Option.isSome) {
                let copy = Dict.make()
                obj->Dict.toArray->Array.forEach(((k, v)) => copy->Dict.set(k, v))
                copy->Dict.set("id", JSON.Encode.string(id))
                JSON.Encode.object(copy)
              } else {
                item
              }
            })
          )
      }
      let ops: ReventlessCore.QueryDb_Adapter.operations = {
        load: async id => Ok(store.contents->Dict.get(id)->Option.getOr([])),
        loadStream: id =>
          store.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable,
        save: async (id, state, _, _) => {
          store.contents->Dict.set(id, [state])
          syncAll()
          Ok()
        },
        saveBatch: async batch => {
          batch->Array.forEach(((id, state, _)) => store.contents->Dict.set(id, [state]))
          syncAll()
          Ok()
        },
        count: async (_, _, inc) => Ok(inc),
        delete: async (id, _) => {
          store.contents->Dict.delete(id)
          syncAll()
          Ok()
        },
        deleteBatch: async ids => {
          ids->Array.forEach(((id, _)) => store.contents->Dict.delete(id))
          syncAll()
          Ok()
        },
      }
      Bus.registerQueryDb(name, ops)
      Bus.registerQueryDbScan(name, () => allItems.contents)
      Bus.registerQueryDbStream(name, () => allItems.contents->Stream.fromIterable)
      platformEventGraphQueryDbOpsRef := Some(ops)
      ops
    }
  }

  // In-memory store for plugin structures, keyed by plugin ID.
  let pluginStructuresStore: ref<dict<Reventless.Plugin.pluginStructure>> = ref(Dict.make())

  let seedPluginStructuresStore = (~pluginComponents: array<ReventlessCore.Plugin.component>) => {
    pluginComponents->Array.forEach(plugin => {
      let outputs: ReventlessInfra.Plugin.outputs = plugin->ReventlessCore.Component.outputs
      let _ =
        (outputs.id, outputs.pluginStructure)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((id, ps)) => {
          switch ps {
          | Some(def) => pluginStructuresStore.contents->Dict.set(id, def)
          | None => ()
          }
        })
    })
  }

  // Seed the Plugin QueryDb from constructed plugin component outputs.
  // Uses real output values serialized via PluginsReadModelSpec.stateSchema.
  let seedPluginQueryDb = (~pluginComponents: array<ReventlessCore.Plugin.component>) => {
    let pluginOps = ensurePluginQueryDbStore()
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
          let state: ReventlessCore.PluginsReadModelSpec.state = {
            name: id->String.split("@")->Array.get(0)->Option.getOr(id),
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
            extensionPointNames: extensionPoints->Dict.keysToArray,
            extensionNames: extensions->Dict.keysToArray,
            extensions: extensions
            ->Dict.toArray
            ->Array.map(
              ((_, ext: ReventlessInfra.Extension.outputs)) => {
                Reventless.Plugin.name: ext.name,
                extensionPointName: ext.extensionPointName,
                dcbSources: [],
              },
            ),
            status: Connected,
            statusChange: {at: Date.make()->Date.toISOString, by: "in-memory"},
            apiSchemaFragment,
            uiFragments,
            structure: pluginStructure,
            dcbEventLog: None,
          }
          let entry =
            state->S.reverseConvertToJsonOrThrow(ReventlessCore.PluginsReadModelSpec.stateSchema)
          let _ = pluginOps.save(id, entry, Any, None)
        })
    })
  }

  // Seed the UIFragmentRegistry QueryDb from plugin outputs that carry a uiFragments manifest.
  let seedUIFragmentRegistryQueryDb = (~pluginComponents: array<ReventlessCore.Plugin.component>) => {
    let uiFragmentOps = ensureUIFragmentRegistryQueryDbStore()
    pluginComponents->Array.forEach(plugin => {
      let outputs: ReventlessInfra.Plugin.outputs = plugin->ReventlessCore.Component.outputs
      let _ =
        (outputs.id, outputs.uiFragments)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((id, uiFragments)) => {
          switch uiFragments {
          | Some(manifest) =>
            let state: ReventlessCore.UIFragmentRegistryReadModelSpec.state = {
              pluginId: id,
              remoteEntryUrl: manifest.remoteEntryUrl,
              panels: manifest.panels,
              pages: manifest.pages,
              registeredAt: Date.make()->Date.toISOString,
              updatedAt: Date.make()->Date.toISOString,
            }
            let entry =
              state->S.reverseConvertToJsonOrThrow(
                ReventlessCore.UIFragmentRegistryReadModelSpec.stateSchema,
              )
            let _ = uiFragmentOps.save(id, entry, Any, None)
          | None => ()
          }
        })
    })
  }

  // Seed the PlatformEventGraph QueryDb from plugin structures (one row per plugin).
  // Mirrors the AWS-side PlatformEventGraphReadModel projection: derives nodes and edges
  // from the plugin structure via Platform_EventGraphReadModelSpec.buildEntry.
  let seedPlatformEventGraphQueryDb = (
    ~pluginComponents: array<ReventlessCore.Plugin.component>,
  ) => {
    let ops = ensurePlatformEventGraphQueryDbStore()
    pluginComponents->Array.forEach(plugin => {
      let outputs: ReventlessInfra.Plugin.outputs = plugin->ReventlessCore.Component.outputs
      let _ =
        (outputs.id, outputs.pluginStructure)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((id, ps)) => {
          switch ps {
          | Some(structure) =>
            let pluginName = id->String.split("@")->Array.get(0)->Option.getOr(id)
            let state = ReventlessCore.Platform_EventGraphReadModelSpec.buildEntry(
              ~pluginName,
              structure,
            )
            let entry =
              state->S.reverseConvertToJsonOrThrow(
                ReventlessCore.Platform_EventGraphReadModelSpec.stateSchema,
              )
            let _ = ops.save(id, entry, Any, None)
          | None => ()
          }
        })
    })
  }

  // Seed the synthetic admin plugin's event-graph entry. Admin.construct does not
  // flow through pluginStructure outputs, so we register the row manually — same
  // pattern as the pluginStructuresStore admin entry.
  let seedAdminPlatformEventGraphEntry = () => {
    let ops = ensurePlatformEventGraphQueryDbStore()
    let adminId = ReventlessCore.Platform_Admin_Structure.pluginId
    let adminName = adminId->String.split("@")->Array.get(0)->Option.getOr(adminId)
    let state = ReventlessCore.Platform_EventGraphReadModelSpec.buildEntry(
      ~pluginName=adminName,
      ReventlessCore.Platform_Admin_Structure.structure,
    )
    let entry =
      state->S.reverseConvertToJsonOrThrow(
        ReventlessCore.Platform_EventGraphReadModelSpec.stateSchema,
      )
    let _ = ops.save(adminId, entry, Any, None)
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
      DomainGraphQL_Server.start()
      DomainMCP_Server.start()
      PlatformGraphQL_Server.start(
        ~port=4001,
        ~contextFactory=Auth_GraphqlContext.buildAuthContext,
        (),
      )
      PlatformMCP_Server.start(~port=3002, ())
    }
    if graphqlDebug {
      DomainGraphQL_Server.printDiagnostics()
      DomainMCP_Server.printDiagnostics()
      if Config.splitApi {
        PlatformGraphQL_Server.printDiagnostics()
        PlatformMCP_Server.printDiagnostics()
      }
    }
    // Fire onPlatformDeployed after all servers are started so late-deployed
    // plugins (e.g. PlatformInspector) have their handler refs populated.
    ReventlessCore.Plugin_Helpers.firePlatformDeployedHook({
      name: "in-memory",
      environment: Pulumi.Pulumi.getStackName(),
      region: "local",
      domainApiEndpoint: "http://localhost:4000/graphql",
      domainApiRoleArn: "in-memory",
      platformApiEndpoint: if Config.splitApi {
        "http://localhost:4001/graphql"
      } else {
        "http://localhost:4000/graphql"
      },
      platformApiRoleArn: "in-memory",
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

  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    log.info(~comp="Platform", `v${version}`)
    log.info(
      ~comp="Platform",
      `silent: ${Config.silent->Bool.toString}, splitApi: ${Config.splitApi->Bool.toString}, cloner: ${Config.cloner->Bool.toString}`,
    )
    log.info(
      ~comp="Platform",
      switch Config.backend {
      | Backend.Memory => "backend: memory"
      | Backend.Sqlite({path, resetOnStart}) =>
        `backend: sqlite (${path}${resetOnStart ? ", resetOnStart" : ""})`
      },
    )
    // Create scheduler and populate platform context refs.
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: ()->Obj.magic})
    hooks.apiRole := Some({val: ()->Obj.magic})

    let admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[module(InMemoryPluginAggregate)],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=InMemory_PluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~stateChangeSlices=[],
      ~stateViewSlices=[],
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
    // We chain the existing hook (SdkService_InMemory registration) so it still fires.
    let environment = Pulumi.Pulumi.getStackName()
    let existingBuiltHook = ReventlessCore.Plugin_Helpers.onPluginBuiltHook.contents
    let builtInfos: ref<array<ReventlessCore.Plugin_Helpers.pluginBuiltInfo>> = ref([])
    ReventlessCore.Plugin_Helpers.registerOnPluginBuilt(info => {
      existingBuiltHook->Option.forEach(h => h(info))
      builtInfos.contents->Array.push(info)
    })

    // Build each plugin.
    let plugins = plugins->Array.map(plugin => {
      module P = unpack(plugin)
      P.make()
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
      name: "in-memory",
      environment,
      region: "local",
      domainApiEndpoint: "http://localhost:4000/graphql",
      domainApiRoleArn: "in-memory",
      platformApiEndpoint: "http://localhost:4000/graphql",
      platformApiRoleArn: "in-memory",
      adminResources: [],
    })

    // Seed the Plugin QueryDb from constructed plugin component outputs.
    // Initializes the store on first call and serializes via PluginsReadModelSpec.stateSchema.
    seedPluginQueryDb(~pluginComponents=plugins)
    seedUIFragmentRegistryQueryDb(~pluginComponents=plugins)
    seedPluginStructuresStore(~pluginComponents=plugins)
    seedPlatformEventGraphQueryDb(~pluginComponents=plugins)

    // Seed the built-in admin plugin's structure so its Auto UI (Plugin list with
    // Activate/Deactivate buttons, PlatformEventGraph view) renders alongside the
    // user plugins. Admin.construct does not flow through pluginStructure outputs,
    // so we register the synthetic structure manually.
    pluginStructuresStore.contents->Dict.set(
      ReventlessCore.Platform_Admin_Structure.pluginId,
      ReventlessCore.Platform_Admin_Structure.structure,
    )
    seedAdminPlatformEventGraphEntry()

    let pluginQueryDbName = ReventlessCore.PluginsReadModelSpec.name
    let uiFragmentQueryDbName = ReventlessCore.UIFragmentRegistryReadModelSpec.name

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
    let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
    let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)

    // Register the admin Plugin aggregate's types/queries/mutations to the platform target.
    let platformGraphQL = resolveTargetGraphQL()
    let platformMCP = resolveTargetMCP()
    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
      ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
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
    // Platform_PlatformEventGraph[s] — backed by the PlatformEventGraph QueryDb
    // seeded from plugin structures (mirrors AWS PlatformEventGraphReadModel projection).
    // The QueryDb scan auto-injects `id` from the store key, satisfying the GraphQL
    // Node interface requirement on edges[].node.id.
    let eventGraphQueryEntry = ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(1)
    let platformEventGraphQueryDbName = ReventlessCore.Platform_EventGraphReadModelSpec.name
    queryResolvers->Dict.set(
      eventGraphQueryEntry.singleFieldName,
      async (_root, args, _ctx): JSON.t => {
        let id =
          args
          ->JSON.Decode.object
          ->Option.flatMap(d => d->Dict.get("id"))
          ->Option.flatMap(JSON.Decode.string)
          ->Option.getOr("")
        switch Bus.getQueryDb(platformEventGraphQueryDbName) {
        | Some(ops) =>
          let items =
            await ops.loadStream(id)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
          // loadStream returns the raw stored entry without id — inject it here
          // so node.id resolves (the list resolver gets this for free via scanAll).
          switch items->Array.get(0) {
          | Some(item) =>
            let obj = item->JSON.Decode.object->Option.getOr(Dict.make())
            let copy = Dict.make()
            obj->Dict.toArray->Array.forEach(((k, v)) => copy->Dict.set(k, v))
            copy->Dict.set("id", JSON.Encode.string(id))
            JSON.Encode.object(copy)
          | None => JSON.Encode.null
          }
        | None => JSON.Encode.null
        }
      },
    )
    queryResolvers->Dict.set(
      eventGraphQueryEntry.listFieldName,
      async (_root, _args, _ctx): JSON.t => {
        let items = switch Bus.getQueryDbScan(platformEventGraphQueryDbName) {
        | Some(scanAll) => scanAll()
        | None => []
        }
        connectionResponse(items)
      },
    )

    // Platform_UIDefinitions resolver — SDL is already stitched into baseParts via
    // AdminApi.baseFragment so we register only the resolver here. Encoder is shared
    // with the AWS adapter so responses are byte-identical.
    //
    // Filter by plugin lifecycle status to mirror the AWS DynamoDB filter in
    // Platform_UIDefinitions_Lambda.res (`contains(#status, :connected)`). Plugins
    // whose Plugin RM row is not Connected are hidden until reactivated. The built-in
    // Platform_Admin entry has no Plugin RM row — include it unconditionally since
    // it can't be deactivated.
    queryResolvers->Dict.set(
      "Platform_UIDefinitions",
      async (_root, _args, _ctx): JSON.t => {
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
        pluginStructuresStore.contents
        ->Dict.toArray
        ->Array.filter(((pluginId, _)) =>
          pluginId === adminPluginId ||
            switch pluginStatusById->Dict.get(pluginId) {
            | Some(Connected) => true
            | _ => false
            }
        )
        ->Array.map(((pluginId, def)) =>
          ReventlessCore.Platform_UIDefinitionsApi.encodePluginStructureEntry(~pluginId, def)
        )
        ->JSON.Encode.array
      },
    )

    // Platform_UIFragments resolver — reads the seeded UIFragmentRegistry QueryDb
    // (same store the admin UIFragment / UIFragments queries scan) and encodes via
    // the shared Platform_UIFragmentsApi encoder so AWS and in-memory return the
    // same JSON shape.
    queryResolvers->Dict.set(
      "Platform_UIFragments",
      async (_root, _args, _ctx): JSON.t => {
        let items = switch Bus.getQueryDbScan(uiFragmentQueryDbName) {
        | Some(scanAll) => scanAll()
        | None => []
        }
        items
        ->Array.filterMap(item =>
          switch item->S.parseOrThrow(
            ReventlessCore.UIFragmentRegistryReadModelSpec.stateSchema,
          ) {
          | state => Some(ReventlessCore.Platform_UIFragmentsApi.encodeUIFragmentEntry(state))
          | exception _ => None
          }
        )
        ->JSON.Encode.array
      },
    )

    platformGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    // Helper: extract plugin id from mutation args, load state, apply status change, save.
    let statusToString = (s: ReventlessCore.PluginsReadModelSpec.status) =>
      switch s {
      | Connected => "Connected"
      | Disconnected => "Disconnected"
      | Inactive => "Inactive"
      }
    let pluginStatusSubTopic = "onPluginStatusChange"
    let publishPluginStatusChange = (~pluginId, ~status) =>
      GraphQL_SubscriptionResolvers_InMemory.publish(
        pluginStatusSubTopic,
        JSON.Encode.object(
          Dict.fromArray([
            ("pluginId", JSON.Encode.string(ReventlessCore.Plugin.name(pluginId))),
            ("status", JSON.Encode.string(status)),
          ]),
        ),
      )

    let updatePluginStatus = async (
      ~field: string,
      args: JSON.t,
      newStatus: ReventlessCore.PluginsReadModelSpec.status,
    ) => {
      let msgId = ReventlessCore.Message.uuid()
      let id =
        args
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("id"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.getOr("")
      log.info(~comp="Admin", `${field}(${id}): received command (msgId: ${msgId})`)
      switch Bus.getQueryDb(pluginQueryDbName) {
      | Some(ops) =>
        let items = await ops.loadStream(id)
        ->Stream.runCollect
        ->Effect.catchAll(_ => Effect.succeed([]))
        ->Effect.runPromise
        switch items->Array.get(0) {
        | Some(json) =>
          switch json->S.convertOrThrow(ReventlessCore.PluginsReadModelSpec.stateSchema) {
          | state =>
            let previousStatus = state.status->statusToString
            let updated = {
              ...state,
              status: newStatus,
              statusChange: {at: Date.make()->Date.toISOString, by: "in-memory"},
            }
            let entry =
              updated->S.reverseConvertToJsonOrThrow(ReventlessCore.PluginsReadModelSpec.stateSchema)
            let _ = await ops.save(id, entry, Any, None)
            log.info(~comp="Admin", `${field}(${id}): ${previousStatus} → ${newStatus->statusToString}`)
            // Source C: fan the new status out to live onPluginStatusChange subscribers.
            publishPluginStatusChange(~pluginId=id, ~status=newStatus->statusToString)
          | exception e =>
            log.error(
              ~comp="Admin",
              `${field}(${id}): failed to decode plugin state: ${e
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("unknown error")}`,
            )
          }
        | None => log.warn(~comp="Admin", `${field}(${id}): plugin not found`)
        }
      | None => log.warn(~comp="Admin", `${field}(${id}): Plugin QueryDb not registered`)
      }
      commandAccepted(~msgId, ~entityId=id)
    }

    // Real resolvers for admin mutations — update plugin state in QueryDb.
    //
    // Activate replays the AWS event flow as two sequential writes, mirroring
    // `PluginsProjection.res`:
    //   1. `Activated` event → status Disconnected
    //   2. Plugin reconnects → `Reconnected` event → status Connected
    // In Lambda the second step is driven by the plugin process noticing the
    // status flip and emitting `Reconnect`; in-memory plugins are loaded in
    // the same process and have nothing to "reconnect", so the resolver
    // synthesises both transitions back-to-back. Both fire onPluginStatusChange
    // subscription events, matching what subscribers would see against
    // AppSync.
    let activateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Activate")
    let deactivateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Deactivate")
    let mutationResolvers = Dict.make()
    mutationResolvers->Dict.set(activateField, async (_root, args, _ctx): JSON.t => {
      let _ = await updatePluginStatus(~field=activateField, args, Disconnected)
      await updatePluginStatus(~field=activateField, args, Connected)
    })
    mutationResolvers->Dict.set(deactivateField, async (_root, args, _ctx): JSON.t =>
      await updatePluginStatus(~field=deactivateField, args, Inactive)
    )
    // Remaining admin mutations (e.g., Clone) are no-ops in-memory.
    adminMutationFieldNames->Array.forEach(field =>
      if mutationResolvers->Dict.get(field)->Option.isNone {
        mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t =>
          commandAccepted(~msgId=ReventlessCore.Message.uuid())
        )
      }
    )
    // UIFragment Source C mutations — publish to PubSub so onUIFragmentChange fires.
    let uiFragmentSubTopic = "onUIFragmentChange"
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
        GraphQL_SubscriptionResolvers_InMemory.publish(uiFragmentSubTopic, event)
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
    platformGraphQL.registerMutations(~sdlFields=adminMutationSdl(baseParts.mutations), ~resolvers=mutationResolvers)
    adminRegisteredServers.contents->Array.push(platformGraphQL)
    // Register onUIFragmentChange + onPluginStatusChange subscriptions (Source C).
    platformGraphQL.registerSubscriptions(
      ~sdlFields=[
        "  onUIFragmentChange: UIFragmentChangeEvent",
        "  onPluginStatusChange: PluginStatusChangeEvent",
      ],
      ~resolvers=Dict.fromArray([
        (
          "onUIFragmentChange",
          GraphQL_SubscriptionResolvers_InMemory.makeFieldResolver(uiFragmentSubTopic),
        ),
        (
          "onPluginStatusChange",
          GraphQL_SubscriptionResolvers_InMemory.makeFieldResolver(pluginStatusSubTopic),
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
      ~pluginName="Admin",
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
      ~pluginName="Admin",
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

    // Register platformCrossPluginEdges query — reads from pluginStructuresStore at query time.
    platformGraphQL.registerTypes(~sdlTypes=ReventlessCore.Platform_CrossPluginEdges.sdlTypes)
    platformGraphQL.registerQueries(
      ~sdlFields=[ReventlessCore.Platform_CrossPluginEdges.sdlQueryField],
      ~resolvers=Dict.fromArray([
        (
          "platformCrossPluginEdges",
          async (_root, _args, _ctx): JSON.t => {
            let encodeNode = (n: Reventless.Plugin.graphNode) =>
              Dict.fromArray([
                ("pluginName", JSON.Encode.string(n.pluginName)),
                ("componentName", JSON.Encode.string(n.componentName)),
                ("kind", JSON.Encode.string(n.kind)),
              ])->JSON.Encode.object
            let encodeEdge = (e: Reventless.Plugin.graphEdge) =>
              Dict.fromArray([
                ("source", encodeNode(e.source)),
                ("target", encodeNode(e.target)),
                ("mechanism", JSON.Encode.string(e.mechanism)),
                ("viaEvents", e.viaEvents->Array.map(JSON.Encode.string)->JSON.Encode.array),
                ("implicit", JSON.Encode.bool(e.implicit)),
              ])->JSON.Encode.object
            pluginStructuresStore.contents
            ->Dict.toArray
            ->ReventlessCore.Platform_CrossPluginEdges.computeEdges
            ->Array.map(encodeEdge)
            ->JSON.Encode.array
          },
        ),
      ]),
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

  // In-memory ignores `~hostUiBundle` — the host shell is served by `vite dev`
  // against the running in-process GraphQL server, not from a CDN.
  type hostUiBundleConfig = {
    assetsDir: string,
    bundleVersion: string,
  }
  let deployPlatform = (~version, ~hostUiBundle as _: option<hostUiBundleConfig>=?) => {
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
      ~resourceNaming=InMemory_PluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~stateChangeSlices=[],
      ~stateViewSlices=[],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )

    // Route admin schema to PlatformGraphQL_Server in split mode, DomainGraphQL_Server otherwise.
    currentDeployTarget.contents = Platform
    let adminGraphQL = resolveTargetGraphQL()
    let adminMCP = resolveTargetMCP()

    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
      ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
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
    let eventGraphQueryEntry2 =
      ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(1)
    queryResolvers->Dict.set(
      eventGraphQueryEntry2.singleFieldName,
      async (_root, _args, _ctx): JSON.t => JSON.Encode.null,
    )
    queryResolvers->Dict.set(
      eventGraphQueryEntry2.listFieldName,
      async (_root, _args, _ctx): JSON.t => connectionResponse([]),
    )
    // Platform_UIFragments — empty in the platform-only path (no plugins
    // connected → no UI fragments registered). The SDL declares it as a
    // non-null array so we must register a resolver returning [].
    queryResolvers->Dict.set(
      "Platform_UIFragments",
      async (_root, _args, _ctx): JSON.t => JSON.Encode.array([]),
    )
    adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    let mutationResolvers = Dict.make()
    let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
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
        GraphQL_SubscriptionResolvers_InMemory.publish(dpSubTopic, event)
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
          GraphQL_SubscriptionResolvers_InMemory.makeFieldResolver(dpSubTopic),
        ),
        (
          "onPluginStatusChange",
          GraphQL_SubscriptionResolvers_InMemory.makeFieldResolver("onPluginStatusChange"),
        ),
      ]),
    )

    currentDeployTarget.contents = Domain

    // Start servers immediately (deployPlatform is always called standalone).
    // Wire `Auth_GraphqlContext.buildAuthContext` so the admin yoga server
    // extracts identity from the bearer token, same as the Domain server.
    // Without this, Platform_* queries / mutations run as `anonymous` and
    // skip the group authorization that AppSync would enforce via
    // `@aws_auth(cognito_groups: ["Admin"])` in production. The Domain
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

    // Fire onPlatformDeployed hook with in-memory platform metadata.
    ReventlessCore.Plugin_Helpers.firePlatformDeployedHook({
      name: "in-memory",
      environment: "local",
      region: "local",
      domainApiEndpoint: "http://localhost:4000/graphql",
      domainApiRoleArn: "in-memory",
      platformApiEndpoint: if Config.splitApi {
        "http://localhost:4001/graphql"
      } else {
        "http://localhost:4000/graphql"
      },
      platformApiRoleArn: "in-memory",
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
      ~aggregates=[module(InMemoryPluginAggregate)],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=InMemory_PluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~stateChangeSlices=[],
      ~stateViewSlices=[],
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

    module P = unpack(plugin)
    let pluginComponent = P.make()

    ReventlessCore.Plugin_Helpers.onPluginBuiltHook.contents = existingBuiltHook

    // Register admin schema to the correct target (domain or platform).
    // Skip if already registered by makePlatform (both target the same server).
    let adminGraphQL = resolveTargetGraphQL()
    if !(adminRegisteredServers.contents->Array.some(s => s === adminGraphQL)) {
      let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
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
      // Platform_UIFragments — single-plugin path. Seeded by
      // seedUIFragmentRegistryQueryDb below if the plugin component carries
      // a uiFragments manifest, otherwise scans an empty store.
      queryResolvers->Dict.set(
        "Platform_UIFragments",
        async (_root, _args, _ctx): JSON.t => {
          let items = switch Bus.getQueryDbScan(
            ReventlessCore.UIFragmentRegistryReadModelSpec.name,
          ) {
          | Some(scanAll) => scanAll()
          | None => []
          }
          items
          ->Array.filterMap(item =>
            switch item->S.parseOrThrow(
              ReventlessCore.UIFragmentRegistryReadModelSpec.stateSchema,
            ) {
            | state =>
              Some(ReventlessCore.Platform_UIFragmentsApi.encodeUIFragmentEntry(state))
            | exception _ => None
            }
          )
          ->JSON.Encode.array
        },
      )
      let eventGraphQueryEntry3 =
        ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(1)
      // Single-plugin path: derive the entry on-demand from pluginStructuresStore
      // (seeded after this resolver block runs, but resolvers are called at query time).
      queryResolvers->Dict.set(
        eventGraphQueryEntry3.singleFieldName,
        async (_root, args, _ctx): JSON.t => {
          let id =
            args
            ->JSON.Decode.object
            ->Option.flatMap(d => d->Dict.get("id"))
            ->Option.flatMap(JSON.Decode.string)
            ->Option.getOr("")
          switch pluginStructuresStore.contents->Dict.get(id) {
          | Some(structure) =>
            let pluginName = id->String.split("@")->Array.get(0)->Option.getOr(id)
            let state = ReventlessCore.Platform_EventGraphReadModelSpec.buildEntry(
              ~pluginName,
              structure,
            )
            state->S.reverseConvertToJsonOrThrow(
              ReventlessCore.Platform_EventGraphReadModelSpec.stateSchema,
            )
          | None => JSON.Encode.null
          }
        },
      )
      queryResolvers->Dict.set(
        eventGraphQueryEntry3.listFieldName,
        async (_root, _args, _ctx): JSON.t => {
          let items =
            pluginStructuresStore.contents
            ->Dict.toArray
            ->Array.map(((id, structure)) => {
              let pluginName = id->String.split("@")->Array.get(0)->Option.getOr(id)
              let state = ReventlessCore.Platform_EventGraphReadModelSpec.buildEntry(
                ~pluginName,
                structure,
              )
              state->S.reverseConvertToJsonOrThrow(
                ReventlessCore.Platform_EventGraphReadModelSpec.stateSchema,
              )
            })
          connectionResponse(items)
        },
      )
      // Platform_UIDefinitions resolver — SDL is already stitched into baseParts via
      // AdminApi.baseFragment so we register only the resolver here. Uses the shared
      // encoder so the dynamic-plugin admin server emits the same canonical shape as
      // the main platform server (and as AWS).
      queryResolvers->Dict.set(
        "Platform_UIDefinitions",
        async (_root, _args, _ctx): JSON.t =>
          pluginStructuresStore.contents
          ->Dict.toArray
          ->Array.map(((pluginId, def)) =>
            ReventlessCore.Platform_UIDefinitionsApi.encodePluginStructureEntry(~pluginId, def)
          )
          ->JSON.Encode.array,
      )
      adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

      let mutationResolvers = Dict.make()
      let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
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
          GraphQL_SubscriptionResolvers_InMemory.publish(dpSubTopic2, event)
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
            GraphQL_SubscriptionResolvers_InMemory.makeFieldResolver(dpSubTopic2),
          ),
        ]),
      )
      // Register platformCrossPluginEdges query.
      adminGraphQL.registerTypes(~sdlTypes=ReventlessCore.Platform_CrossPluginEdges.sdlTypes)
      adminGraphQL.registerQueries(
        ~sdlFields=[ReventlessCore.Platform_CrossPluginEdges.sdlQueryField],
        ~resolvers=Dict.fromArray([
          (
            "platformCrossPluginEdges",
            async (_root, _args, _ctx): JSON.t => {
              let encodeNode = (n: Reventless.Plugin.graphNode) =>
                Dict.fromArray([
                  ("pluginName", JSON.Encode.string(n.pluginName)),
                  ("componentName", JSON.Encode.string(n.componentName)),
                  ("kind", JSON.Encode.string(n.kind)),
                ])->JSON.Encode.object
              let encodeEdge = (e: Reventless.Plugin.graphEdge) =>
                Dict.fromArray([
                  ("source", encodeNode(e.source)),
                  ("target", encodeNode(e.target)),
                  ("mechanism", JSON.Encode.string(e.mechanism)),
                  ("viaEvents", e.viaEvents->Array.map(JSON.Encode.string)->JSON.Encode.array),
                  ("implicit", JSON.Encode.bool(e.implicit)),
                ])->JSON.Encode.object
              pluginStructuresStore.contents
              ->Dict.toArray
              ->ReventlessCore.Platform_CrossPluginEdges.computeEdges
              ->Array.map(encodeEdge)
              ->JSON.Encode.array
            },
          ),
        ]),
      )
      adminRegisteredServers.contents->Array.push(adminGraphQL)
    }

    // Reset deploy target back to Domain for subsequent calls.
    currentDeployTarget.contents = Domain
    StateViewSliceMaker.QueryDbResolvers.serverRef.contents = DomainGraphQL_Server.asInterface
    StateViewSliceMaker.QueryDbResolvers.relayRef.contents = Some(domainRelaySupport)

    // Seed the Plugin, UIFragmentRegistry, and UIDefinitions stores so this plugin appears in queries.
    seedPluginQueryDb(~pluginComponents=[pluginComponent])
    seedUIFragmentRegistryQueryDb(~pluginComponents=[pluginComponent])
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
