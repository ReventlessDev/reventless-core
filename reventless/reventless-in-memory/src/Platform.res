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
// splitApi=true to serve core and plugin APIs on separate ports.
// Usage: module Platform = Platform.MakeWithConfig({let silent = true; let splitApi = false; let cloner = false})
module MakeWithConfig = (
  Config: {
    let silent: bool
    let splitApi: bool
    let cloner: bool
  },
): (ReventlessInfra.Platform.T with type api = unit and type role = unit) => {
  // Activate Pulumi mock mode — must happen before any component creation.
  // Idempotent, so safe to call even if TestRunner.setup() was already called.
  let _ = TestRunner.setup()

  type api = unit
  type role = unit
  type apiTarget = Domain | Platform

  let api = ()
  let apiRole = ()

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
    api: ref(None),
    apiRole: ref(None),
    // Phase 1: register SDL + resolver stub synchronously.
    // Pass the resolved server so the correct target (domain or platform) receives the schema.
    mutationResolverHook: (~kind, ~fields, ~commandSchema) => {
      let server = resolveTargetGraphQL()
      switch kind {
      | ReventlessCore.Plugin_Helpers.Aggregate =>
        CommandGeneratorResolvers_GraphQL.register(~fields, ~commandSchema, ~server)
      | Dcb =>
        fields->Array.forEach(field =>
          CommandGeneratorResolvers_GraphQL.registerDcb(~fieldName=field, ~commandSchema, ~server)
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
    mcpSchemaRegistrationHook: ({pluginName, mutationEntries, queryEntries, eventLogEntries}) => {
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
            await generateCommand(payload)->Effect.runPromise
          | None => `error: no handler for ${toolName}`
          }
        | None => `error: no handler for ${toolName}`
        }
      })

      mcp.registerResourcesFromEntries(~pluginName, ~queryEntries, ~queryHandler=async (
        resourceName,
        uri,
      ) => {
        let segments = uri->String.split("/")
        let id = segments->Array.at(-1)->Option.getOr("")
        let queryDbName =
          ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry.contents
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
                  ->Dict.get("seq")
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
      Config: {let moduleUrl: string},
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping.ExtensionPoint
      module CompiledMapping = ReventlessInfra.ExtensionPointMapping.Make(Mapping)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name = Mapping.Delegate.name
        let moduleUrl = Config.moduleUrl
        let mappings: array<module(Mapping)> = [module(CompiledMapping)]
      }
      module Inner = ExtensionPointMaker.Make(Spec, Mappings)
      include Inner
    }

    module Make2 = (
      Mapping1: ReventlessInfra.ExtensionPointMapping.Mapping,
      Mapping2: ReventlessInfra.ExtensionPointMapping.Mapping
        with module ExtensionPoint = Mapping1.ExtensionPoint,
      Config: {let moduleUrl: string},
    ): ReventlessInfra.ExtensionPoint.T => {
      module Spec = Mapping1.ExtensionPoint
      module CM1 = ReventlessInfra.ExtensionPointMapping.Make(Mapping1)
      module CM2 = ReventlessInfra.ExtensionPointMapping.Make(Mapping2)
      module Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec = {
        module type Mapping = ReventlessInfra.ExtensionPointMapping.T
          with module ExtensionPoint := Spec
        let name =
          Mapping1.Delegate.name ++ "+" ++ Mapping2.Delegate.name
        let moduleUrl = Config.moduleUrl
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
      Config: {let moduleUrl: string},
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
        let moduleUrl = Config.moduleUrl
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
      let moduleUrl = Mapping.Delegate.moduleUrl
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
    module Make = (Spec: Reventless.StateChangeSlice.Spec): (
      ReventlessInfra.StateChangeSlice.T with module Spec = Spec
    ) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = {
    module Make = (Spec: Reventless.StateViewSlice.Spec): (
      ReventlessInfra.StateViewSlice.T with module Spec = Spec
    ) => StateViewSliceMaker.Make(Spec)
  }

  module AutomationSlice = {
    module Make = (Spec: Reventless.AutomationSlice.Spec): (
      ReventlessInfra.AutomationSlice.T with module Spec = Spec
    ) => AutomationSliceMaker.Make(Spec)
  }

  module OutboundTranslationSlice = {
    module Make = (Spec: Reventless.OutboundTranslationSlice.Spec): (
      ReventlessInfra.OutboundTranslationSlice.T with module Spec = Spec
    ) => OutboundTranslationSliceMaker.Make(Spec)
  }

  module InboundTranslationSlice = {
    module Make = (Spec: Reventless.InboundTranslationSlice.Spec): (
      ReventlessInfra.InboundTranslationSlice.T with module Spec = Spec
    ) => InboundTranslationSliceMaker.Make(Spec)
  }

  // Empty base fragment — no types, no mutations, no queries.
  // Used by the plugin Api in split mode so plugin schema has no core fields.
  let emptyBaseFragment = ReventlessCore.GraphQL_Stitcher.encode({
    types: [],
    mutations: [],
    queries: [],
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
  }

  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module QE = QueryEngine_InMemory.Make(Bus)
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
      let pluginQueryDbName = ReventlessCore.PluginReadModelSpec.name
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

  // Seed the Plugin QueryDb from constructed plugin component outputs.
  // Uses real output values serialized via PluginReadModelSpec.stateSchema.
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
        )
        ->Pulumi.Output.all6
        ->Pulumi.Output.apply(((
          id,
          version,
          eventCollector,
          extensionPoints,
          extensions,
          apiSchemaFragment,
        )) => {
          let state: ReventlessCore.PluginReadModelSpec.state = {
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
              },
            ),
            status: Connected,
            statusChange: {at: Date.make()->Date.toISOString, by: "in-memory"},
            apiSchemaFragment,
          }
          let entry =
            state->S.reverseConvertToJsonOrThrow(ReventlessCore.PluginReadModelSpec.stateSchema)
          let _ = pluginOps.save(id, entry, Any, None)
        })
    })
  }

  // Fire onPluginDeployed hooks for each plugin that was built.
  let firePluginDeployedHooks = (
    ~builtInfos: array<ReventlessCore.Plugin_Helpers.pluginBuiltInfo>,
  ) => {
    let environment = Pulumi.Pulumi.getStackName()
    builtInfos->Array.forEach(info => {
      switch ReventlessCore.Plugin_Helpers.onPluginDeployedHook.contents {
      | Some(hook) =>
        let deployedInfo: ReventlessCore.Plugin_Helpers.pluginDeployedInfo = {
          name: info.name,
          version: info.version,
          environment,
          stackName: environment,
          components: info.components->Array.map(
            (c): ReventlessCore.Plugin_Helpers.pluginDeployedComponent => {
              name: c.name,
              kind: c.kind,
              schema: c.schema,
              resources: [],
              subComponents: [],
            },
          ),
          extensionWirings: [],
        }
        hook(deployedInfo)
      | None => ()
      }
    })
  }

  // Start all servers. In split mode this is deferred — called explicitly by the
  // caller after all makePlatform/deployPlugin calls are complete. In unified mode
  // this is a no-op (start() is called inline inside makePlatform/deployPlugin).
  let startServers = () => {
    if Config.splitApi {
      DomainGraphQL_Server.start()
      DomainMCP_Server.start()
      PlatformGraphQL_Server.start(~port=4001, ())
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
  }

  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    log.info(~comp="Platform", `v${version}`)
    log.info(
      ~comp="Platform",
      `silent: ${Config.silent->Bool.toString}, splitApi: ${Config.splitApi->Bool.toString}, cloner: ${Config.cloner->Bool.toString}`,
    )
    // Create scheduler and populate platform context refs.
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: ()->Obj.magic})
    hooks.apiRole := Some({val: ()->Obj.magic})

    let admin = Admin.construct(
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
    firePluginDeployedHooks(~builtInfos=builtInfos.contents)
    switch ReventlessCore.Plugin_Helpers.onPlatformDeployedHook.contents {
    | Some(hook) =>
      hook({
        name: "in-memory",
        environment,
        region: "local",
        domainApiEndpoint: "http://localhost:4000/graphql",
        domainApiRoleArn: "in-memory",
        platformApiEndpoint: "http://localhost:4000/graphql",
        platformApiRoleArn: "in-memory",
        adminResources: [],
      })
    | None => ()
    }

    // Seed the Plugin QueryDb from constructed plugin component outputs.
    // Initializes the store on first call and serializes via PluginReadModelSpec.stateSchema.
    seedPluginQueryDb(~pluginComponents=plugins)

    let pluginQueryDbName = ReventlessCore.PluginReadModelSpec.name

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
      Dict.fromArray([
        ("nextToken", JSON.Encode.null),
        ("scannedCount", JSON.Encode.int(items->Array.length)),
        ("items", items->JSON.Encode.array),
      ])->JSON.Encode.object
    })
    platformGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    // Helper: extract plugin id from mutation args, load state, apply status change, save.
    let statusToString = (s: ReventlessCore.PluginReadModelSpec.status) =>
      switch s {
      | Connected => "Connected"
      | Disconnected => "Disconnected"
      | Inactive => "Inactive"
      }
    let updatePluginStatus = async (
      ~field: string,
      args: JSON.t,
      newStatus: ReventlessCore.PluginReadModelSpec.status,
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
          switch json->S.convertOrThrow(ReventlessCore.PluginReadModelSpec.stateSchema) {
          | state =>
            let previousStatus = state.status->statusToString
            let updated = {
              ...state,
              status: newStatus,
              statusChange: {at: Date.make()->Date.toISOString, by: "in-memory"},
            }
            let entry =
              updated->S.reverseConvertToJsonOrThrow(ReventlessCore.PluginReadModelSpec.stateSchema)
            let _ = await ops.save(id, entry, Any, None)
            log.info(~comp="Admin", `${field}(${id}): ${previousStatus} → ${newStatus->statusToString}`)
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
      msgId->JSON.Encode.string
    }

    // Real resolvers for admin mutations — update plugin state in QueryDb.
    let activateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Activate")
    let deactivateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Deactivate")
    let mutationResolvers = Dict.make()
    mutationResolvers->Dict.set(activateField, async (_root, args, _ctx): JSON.t =>
      await updatePluginStatus(~field=activateField, args, Disconnected)
    )
    mutationResolvers->Dict.set(deactivateField, async (_root, args, _ctx): JSON.t =>
      await updatePluginStatus(~field=deactivateField, args, Inactive)
    )
    // Remaining admin mutations (e.g., Clone) are no-ops in-memory.
    adminMutationFieldNames->Array.forEach(field =>
      if mutationResolvers->Dict.get(field)->Option.isNone {
        mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t =>
          JSON.Encode.string("ok")
        )
      }
    )
    platformGraphQL.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=mutationResolvers)
    adminRegisteredServers.contents->Array.push(platformGraphQL)

    // Register admin Plugin queries and mutations as MCP resources and tools.
    let pluginQueryHandler = async (_resourceName, uri) => {
      let segments = uri->String.split("/")
      let id = segments->Array.at(-1)->Option.getOr("")
      switch Bus.getQueryDb(pluginQueryDbName) {
      | Some(ops) =>
        if id->String.length > 0 && id != listQueryField {
          let items = await ops.loadStream(id)
          ->Stream.runCollect
          ->Effect.catchAll(_ => Effect.succeed([]))
          ->Effect.runPromise
          items->Array.get(0)->Option.getOr(JSON.Encode.null)
        } else {
          switch Bus.getQueryDbScan(pluginQueryDbName) {
          | Some(scanAll) => scanAll()->JSON.Encode.array
          | None => []->JSON.Encode.array
          }
        }
      | None => JSON.Encode.null
      }
    }
    platformMCP.registerResourcesFromEntries(
      ~pluginName="Admin",
      ~queryEntries=ReventlessCore.PluginBaseFragment.queryEntries,
      ~queryHandler=pluginQueryHandler,
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
      DomainGraphQL_Server.start()
      DomainMCP_Server.start()
    }

  }

  let deployPlatform = (~version) => {
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
      Dict.fromArray([
        ("nextToken", JSON.Encode.null),
        ("scannedCount", JSON.Encode.int(0)),
        ("items", []->JSON.Encode.array),
      ])->JSON.Encode.object
    )
    adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    let mutationResolvers = Dict.make()
    let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
    let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)
    adminMutationFieldNames->Array.forEach(field =>
      mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t =>
        JSON.Encode.string("ok")
      )
    )
    adminGraphQL.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=mutationResolvers)

    currentDeployTarget.contents = Domain

    // Start servers immediately (deployPlatform is always called standalone).
    adminGraphQL.start(~port=if Config.splitApi { 4001 } else { 4000 }, ())
    adminMCP.start(~port=if Config.splitApi { 3002 } else { 3001 }, ())
    if Config.splitApi {
      DomainGraphQL_Server.start()
      DomainMCP_Server.start()
    }

    // Fire onPlatformDeployed hook with in-memory platform metadata.
    switch ReventlessCore.Plugin_Helpers.onPlatformDeployedHook.contents {
    | Some(hook) =>
      hook({
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
    | None => ()
    }
  }

  let deployPlugin = (~version, ~plugin: module(PluginMaker), ~apiTarget=Domain) => {
    log.info(~comp="Platform", `deployPlugin v${version}`)

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
    let admin = Admin.construct(
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
        Dict.fromArray([
          ("nextToken", JSON.Encode.null),
          ("scannedCount", JSON.Encode.int(0)),
          ("items", []->JSON.Encode.array),
        ])->JSON.Encode.object
      )
      adminGraphQL.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

      let mutationResolvers = Dict.make()
      let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
      let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)
      adminMutationFieldNames->Array.forEach(field =>
        mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t =>
          JSON.Encode.string("ok")
        )
      )
      adminGraphQL.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=mutationResolvers)
      adminRegisteredServers.contents->Array.push(adminGraphQL)
    }

    // Reset deploy target back to Domain for subsequent calls.
    currentDeployTarget.contents = Domain
    StateViewSliceMaker.QueryDbResolvers.serverRef.contents = DomainGraphQL_Server.asInterface
    StateViewSliceMaker.QueryDbResolvers.relayRef.contents = Some(domainRelaySupport)

    // Seed the Plugin QueryDb so this plugin appears in plugin queries.
    seedPluginQueryDb(~pluginComponents=[pluginComponent])

    // Fire onPluginDeployed hooks so subscribers learn about this plugin.
    firePluginDeployedHooks(~builtInfos=builtInfos.contents)

    // In unified mode, start servers immediately (backwards-compatible).
    // In split mode, start() is deferred to startServers().
    if !Config.splitApi {
      switch apiTarget {
      | Domain =>
        DomainGraphQL_Server.start()
        DomainMCP_Server.start()
      | Platform =>
        PlatformGraphQL_Server.start(~port=4001, ())
        PlatformMCP_Server.start(~port=3002, ())
      }
    }

    let pluginOutputs: ReventlessCore.Plugin.outputs =
      (pluginComponent->Obj.magic: ReventlessCore.Plugin.component)->ReventlessCore.Component.outputs
    pluginOutputs
  }
}

// Default platform — diagnostic warnings enabled, split API (admin on separate ports), no cloner.
module Make = (): (ReventlessInfra.Platform.T with type api = unit and type role = unit) => {
  include MakeWithConfig({
    let silent = false
    let splitApi = true
    let cloner = false
  })
}
