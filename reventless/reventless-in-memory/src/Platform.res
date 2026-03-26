// In-memory Platform — implements ReventlessInfra.Platform.T using only in-memory data structures.
// Pulumi mock mode is activated automatically when Platform.Make() is applied.
//
// Example:
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// The platform starts a GraphQL server on port 4000 after all components are built.
// Stop it with TestRunner.stopGraphQLServer() in afterAll.

// Module-level ref to hold the admin GraphQL server instance in split mode.
// Populated by makePlatform when splitApi=true.
let adminGraphQLRef: ref<option<GraphQL_ServerInstance.t>> = ref(None)
let getAdminGraphQL = () => adminGraphQLRef.contents

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

  let api = ()
  let apiRole = ()

  module Bus = InMemory_Bus.Impl({
    let capacity = None
    let silent = Config.silent
  })

  module AggregateMaker = Aggregate_Builder.Make(Bus)
  module ReadModelMaker = ReadModel_Builder.Make(Bus)
  module ExtensionPointMaker = ExtensionPoint_Builder.Make(Bus)
  module TaskMaker = Task_Builder.Make(Bus)
  module DcbEventLogMaker = DcbEventLog_Builder.Make(Bus)
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
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T => ExtensionPointMaker.Make(Spec, Mappings)
  }

  module Extension = {
    module Make = (
      Spec: ReventlessInfra.ExtensionMapping.Spec,
      Mappings: ReventlessInfra.ExtensionMapping.Mappings with module Spec := Spec,
    ): ReventlessInfra.Extension.T => ReventlessCore.Extension_Builder.Make(Spec, Mappings)
  }

  module Task = {
    module Make = (Spec: ReventlessInfra.Task.Spec): (
      ReventlessInfra.Task.T with module Spec = Spec
    ) => TaskMaker.Make(Spec)
  }

  module Counter = Counter_Builder.Make(Bus)

  module StateChangeSlice = {
    module Make = (Spec: Reventless.StateChangeSlice.Spec): (
      ReventlessInfra.StateChangeSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = {
    module Make = (Spec: Reventless.StateViewSlice.Spec): (
      ReventlessInfra.StateViewSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => StateViewSliceMaker.Make(Spec)
    module Bundled = {
      module Make = (
        Spec: Reventless.StateViewSlice.Spec,
      ): (
        ReventlessInfra.StateViewSlice.T
          with type dcbEvent = Spec.DcbEventLogSpec.event
          and module Spec = Spec
      ) => StateViewSliceMaker.Make(Spec)
    }
  }

  module AutomationSlice = {
    module Make = (Spec: Reventless.AutomationSlice.Spec): (
      ReventlessInfra.AutomationSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => AutomationSliceMaker.Make(Spec)
    module Bundled = {
      module Make = (
        Spec: Reventless.AutomationSlice.Spec,
      ): (
        ReventlessInfra.AutomationSlice.T
          with type dcbEvent = Spec.DcbEventLogSpec.event
          and module Spec = Spec
      ) => AutomationSliceMaker.Make(Spec)
    }
  }

  module OutboundTranslationSlice = {
    module Make = (Spec: Reventless.OutboundTranslationSlice.Spec): (
      ReventlessInfra.OutboundTranslationSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => OutboundTranslationSliceMaker.Make(Spec)
    module Bundled = {
      module Make = (
        Spec: Reventless.OutboundTranslationSlice.Spec,
      ): (
        ReventlessInfra.OutboundTranslationSlice.T
          with type dcbEvent = Spec.DcbEventLogSpec.event
          and module Spec = Spec
      ) => OutboundTranslationSliceMaker.Make(Spec)
    }
  }

  module InboundTranslationSlice = {
    module Make = (Spec: Reventless.InboundTranslationSlice.Spec): (
      ReventlessInfra.InboundTranslationSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => InboundTranslationSliceMaker.Make(Spec)
  }

  module DcbEventLog = {
    module Make = (Spec: Reventless.DcbEventLog.Spec): (
      ReventlessInfra.DcbEventLog.T with module Spec = Spec
    ) => DcbEventLogMaker.Make(Spec)
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

  // Set the unified mutation resolver hooks for both Aggregates and DCB
  // StateChangeSlices. Phase 1 (register) dispatches by kind to the appropriate
  // SDL derivation. Phase 2 (bind) is shared.
  let () = ReventlessCore.Plugin_Helpers.mutationResolverHook.contents = Some(
    (~kind, ~fields, ~commandSchema) =>
      switch kind {
      | ReventlessCore.Plugin_Helpers.Aggregate =>
        CommandGeneratorResolvers_GraphQL.register(~fields, ~commandSchema)
      | Dcb =>
        fields->Array.forEach(field =>
          CommandGeneratorResolvers_GraphQL.registerDcb(~fieldName=field, ~commandSchema)
        )
      },
  )
  let () = ReventlessCore.Plugin_Helpers.mutationBindHook.contents = Some(
    CommandGeneratorResolvers_GraphQL.bindHandler,
  )

  // Set the InboundTranslationSlice mutation resolver hooks so Plugin_Builder.construct()
  // registers GraphQL resolvers for each InboundTranslationSlice during plugin construction.
  // Phase 1 (register): SDL + resolver stub synchronously.
  // Phase 2 (bindReceive): bind `receive` when Output.apply resolves.
  let () = ReventlessCore.Plugin_Helpers.inboundMutationResolverHook.contents = Some(
    InboundTranslationResolvers_GraphQL.register,
  )
  let () = ReventlessCore.Plugin_Helpers.inboundMutationBindReceiveHook.contents = Some(
    InboundTranslationResolvers_GraphQL.bindReceive,
  )

  // Set the schema type registration hook so Plugin_Builder.construct() registers
  // GraphQL type definitions (from the generated fragment) into the GraphQL server.
  let () = ReventlessCore.Plugin_Helpers.schemaTypeRegistrationHook.contents = Some(
    sdlTypes => GraphQL_Server.registerTypes(~sdlTypes),
  )

  // Set the MCP schema registration hook so Plugin_Builder.construct() registers
  // MCP tools and resources during plugin construction.
  let () = ReventlessCore.Plugin_Helpers.mcpSchemaRegistrationHook.contents = Some(
    ({pluginName, mutationEntries, queryEntries, eventLogEntries}) => {
      // Register MCP tools — reuse the same GraphQL resolver functions.
      // The GraphQL mutation resolvers are already registered in GraphQL_Server
      // at this point. We look them up by field name and wrap them for MCP.
      MCP_Server.registerToolsFromEntries(~pluginName, ~mutationEntries, ~commandHandler=async (
        toolName,
        args,
      ) => {
        // Look up the GraphQL mutation resolver for this tool name
        switch GraphQL_Server.getMutationResolver(toolName) {
        | Some(resolver) =>
          let result = await resolver(JSON.Encode.null, args, JSON.Encode.null)
          switch result->JSON.Decode.string {
          | Some(s) => s
          | None => result->JSON.stringify
          }
        | None => `error: no handler found for tool ${toolName}`
        }
      })

      // Register MCP resources from query entries (read models).
      // Use the Bus QueryDb registry directly for reads.
      MCP_Server.registerResourcesFromEntries(~pluginName, ~queryEntries, ~queryHandler=async (
        resourceName,
        uri,
      ) => {
        // Extract the ID from the URI (last segment after /)
        let segments = uri->String.split("/")
        let id = segments->Array.at(-1)->Option.getOr("")
        // Find the QueryDb by matching the resource name to registered query field names
        // (match both singleFieldName and listFieldName since list resources use the plural name)
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
            // Single-item lookup
            let items = await ops.loadStream(id)
            ->Stream.runCollect
            ->Effect.catchAll(_ => Effect.succeed([]))
            ->Effect.runPromise
            switch items->Array.get(0) {
            | Some(item) => item
            | None => JSON.Encode.null
            }
          } else {
            // List query
            switch Bus.getQueryDbScan(queryDbName) {
            | Some(scanAll) => scanAll()->JSON.Encode.array
            | None => []->JSON.Encode.array
            }
          }
        | None => JSON.Encode.null
        }
      })

      // Register MCP resources for event history (aggregate EventLog + DCB EventLog).
      // Use the Bus event log registries for reads.
      // Supports pagination via ?limit=N&after=position query params.
      MCP_Server.registerEventHistoryResourcesFromEntries(
        ~pluginName,
        ~eventLogEntries,
        ~eventLogHandler=async (resourceName, uri) => {
          // Parse URI: extract entity ID from path, pagination from query string
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

          // Build paginated response helper
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

          // Apply pagination: skip events before "after" position, limit count
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

          // Find the matching event log entry by resource name
          let matchingEntry =
            eventLogEntries->Array.find(entry =>
              resourceName->String.includes(entry.displayName->String.toLowerCase)
            )
          switch matchingEntry {
          | Some(entry) =>
            // Try aggregate EventLog first
            switch Bus.getEventLogReplay(entry.busKey) {
            | Some(replay) =>
              let events = await replay(entityId)
              // Aggregate events use array index as position
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
              // Try DCB EventLog — read all events, filter by tag value
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
  )

  module PluginMaker = Plugin_Builder.Make(Bus)
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
    },
  )

  module type PluginMaker = {
    let make: (
      ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
      ~api: api,
      ~apiRole: role,
    ) => Plugin.component
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

  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    Console.log(`[Platform] v${version}`)
    Console.log(
      `[Platform] silent: ${Config.silent->Bool.toString}, splitApi: ${Config.splitApi->Bool.toString}, cloner: ${Config.cloner->Bool.toString}`,
    )
    // Create scheduler and admin components internally.
    let scheduler = makeScheduler()
    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=InMemory_PluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~dcbSpec=None,
    )

    // Build each plugin using the shared scheduler.
    let plugins = plugins->Array.map(plugin => {
      module P = unpack(plugin)
      P.make(~scheduler, ~api=(), ~apiRole=())
    })

    // Create an in-memory Plugin QueryDb in the Bus.
    // This mirrors what QueryDbStorage_InMemory does for user read models,
    // providing the runtime store that backs plugin/everyPlugin queries.
    let pluginQueryDbName = ReventlessCore.PluginReadModelSpec.name
    let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
    let allItems: ref<array<JSON.t>> = ref([])
    let syncAll = () => {
      allItems.contents = QueryDbStorage_InMemory.flattenWithId(store.contents)
    }
    let pluginOps: ReventlessCore.QueryDb_Adapter.operations = {
      load: async id => Ok(store.contents->Dict.get(id)->Option.getOr([])),
      loadStream: id => store.contents->Dict.get(id)->Option.getOr([])->Stream.fromIterable,
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
    Bus.registerQueryDbStream(pluginQueryDbName, () => allItems.contents->Stream.fromIterable)

    // Seed the Plugin QueryDb from constructed plugin component outputs.
    // Uses the real output values and serializes via PluginReadModelSpec.stateSchema
    // so the JSON shape stays in sync with the GraphQL type automatically.
    plugins->Array.forEach(plugin => {
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

    // In split mode, create dedicated admin server instances.
    // In unified mode (default), admin schema registers into the plugin singletons.
    let adminGraphQL = if Config.splitApi {
      Some(GraphQL_ServerInstance.make(~label="GraphQL:Admin"))
    } else {
      None
    }
    let adminMCP = if Config.splitApi {
      Some(MCP_ServerInstance.make(~label="MCP:Admin"))
    } else {
      None
    }

    // Helpers that route admin registrations to the correct target.
    let registerAdminTypes = (~sdlTypes) =>
      switch adminGraphQL {
      | Some(inst) => inst.registerTypes(~sdlTypes)
      | None => GraphQL_Server.registerTypes(~sdlTypes)
      }
    let registerAdminQueries = (~sdlFields, ~resolvers) =>
      switch adminGraphQL {
      | Some(inst) => inst.registerQueries(~sdlFields, ~resolvers)
      | None => GraphQL_Server.registerQueries(~sdlFields, ~resolvers)
      }
    let registerAdminMutations = (~sdlFields, ~resolvers) =>
      switch adminGraphQL {
      | Some(inst) => inst.registerMutations(~sdlFields, ~resolvers)
      | None => GraphQL_Server.registerMutations(~sdlFields, ~resolvers)
      }
    let getAdminMutationResolver = fieldName =>
      switch adminGraphQL {
      | Some(inst) => inst.getMutationResolver(fieldName)
      | None => GraphQL_Server.getMutationResolver(fieldName)
      }
    let registerAdminMcpResources = (~pluginName, ~queryEntries, ~queryHandler) =>
      switch adminMCP {
      | Some(inst) => inst.registerResourcesFromEntries(~pluginName, ~queryEntries, ~queryHandler)
      | None => MCP_Server.registerResourcesFromEntries(~pluginName, ~queryEntries, ~queryHandler)
      }
    let registerAdminMcpTools = (~pluginName, ~mutationEntries, ~commandHandler) =>
      switch adminMCP {
      | Some(inst) => inst.registerToolsFromEntries(~pluginName, ~mutationEntries, ~commandHandler)
      | None => MCP_Server.registerToolsFromEntries(~pluginName, ~mutationEntries, ~commandHandler)
      }

    // Derive field names from the schema entries — single source of truth.
    let adminQueryEntry = ReventlessCore.PluginBaseFragment.queryEntries->Array.getUnsafe(0)
    let singleQueryField = adminQueryEntry.singleFieldName
    let listQueryField = adminQueryEntry.listFieldName
    let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
    let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)

    // Register the admin Plugin aggregate's types/queries/mutations.
    // In unified mode these go into GraphQL_Server alongside plugin schema.
    // In split mode they go into a dedicated admin GraphQL instance.
    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
      ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
    )
    registerAdminTypes(~sdlTypes=baseParts.types)

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
    registerAdminQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

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
      Console.log(`[Admin] ${field}(${id}): received command (msgId: ${msgId})`)
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
            Console.log(
              `[Admin] ${field}(${id}): ${previousStatus} → ${newStatus->statusToString}`,
            )
          | exception e =>
            Console.log(
              `[Admin] ${field}(${id}): failed to decode plugin state: ${e
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("unknown error")}`,
            )
          }
        | None =>
          Console.log(`[Admin] ${field}(${id}): plugin not found`)
        }
      | None =>
        Console.log(`[Admin] ${field}(${id}): Plugin QueryDb not registered`)
      }
      msgId->JSON.Encode.string
    }

    // Real resolvers for admin mutations — update plugin state in QueryDb.
    let activateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Activate")
    let deactivateField = ReventlessCore.Api_Naming.adminField(~name="Plugin_Deactivate")
    let mutationResolvers = Dict.make()
    mutationResolvers->Dict.set(
      activateField,
      async (_root, args, _ctx): JSON.t => await updatePluginStatus(~field=activateField, args, Disconnected),
    )
    mutationResolvers->Dict.set(
      deactivateField,
      async (_root, args, _ctx): JSON.t =>
        await updatePluginStatus(~field=deactivateField, args, Inactive),
    )
    // Remaining admin mutations (e.g., Clone) are no-ops in-memory.
    adminMutationFieldNames->Array.forEach(field =>
      if (mutationResolvers->Dict.get(field)->Option.isNone) {
        mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t => JSON.Encode.string("ok"))
      }
    )
    registerAdminMutations(~sdlFields=baseParts.mutations, ~resolvers=mutationResolvers)

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
    registerAdminMcpResources(
      ~pluginName="Admin",
      ~queryEntries=ReventlessCore.PluginBaseFragment.queryEntries,
      ~queryHandler=pluginQueryHandler,
    )

    // Register admin mutations as MCP tools using the same entry-based path as plugins.
    registerAdminMcpTools(
      ~pluginName="Admin",
      ~mutationEntries=adminMutationEntries,
      ~commandHandler=async (toolName, args) => {
        switch getAdminMutationResolver(toolName) {
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

    // Start servers.
    // In unified mode: one GraphQL + one MCP server with all schema combined.
    // In split mode: plugin servers on default ports, admin servers on +1 ports.
    GraphQL_Server.start()
    MCP_Server.start()
    switch adminGraphQL {
    | Some(inst) =>
      inst.start(~port=4001, ())
      adminGraphQLRef := Some(inst)
    | None => ()
    }
    switch adminMCP {
    | Some(inst) => inst.start(~port=3002, ())
    | None => ()
    }

    // Print schema diagnostics when GRAPHQL_DEBUG is set.
    if graphqlDebug {
      GraphQL_Server.printDiagnostics()
      switch adminGraphQL {
      | Some(inst) => inst.printDiagnostics()
      | None => ()
      }
    }
  }

  let deployPlatform = (~version) => {
    Console.log(`[Platform:deployPlatform] v${version}`)
    let scheduler = makeScheduler()
    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=InMemory_PluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~dcbSpec=None,
    )

    // Register admin schema and start servers (admin-only, no plugins).
    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
      ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
    )
    GraphQL_Server.registerTypes(~sdlTypes=baseParts.types)

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
    GraphQL_Server.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    let mutationResolvers = Dict.make()
    let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
    let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)
    adminMutationFieldNames->Array.forEach(field =>
      mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t => JSON.Encode.string("ok"))
    )
    GraphQL_Server.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=mutationResolvers)

    GraphQL_Server.start()
    MCP_Server.start()
  }

  let deployPlugin = (~version, ~plugin: module(PluginMaker)) => {
    Console.log(`[Platform:deployPlugin] v${version}`)
    // Each plugin creates its own scheduler (mirrors AWS behaviour).
    let scheduler = makeScheduler()

    // Admin components are needed in-memory even for single-plugin deploy.
    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=InMemory_PluginSpec.resourceNaming,
      ~api=(),
      ~apiRole=(),
      ~dcbSpec=None,
    )

    module P = unpack(plugin)
    let _plugin = P.make(~scheduler, ~api=(), ~apiRole=())

    // Register admin schema into the shared server alongside plugin schema.
    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(
      ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
    )
    GraphQL_Server.registerTypes(~sdlTypes=baseParts.types)

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
    GraphQL_Server.registerQueries(~sdlFields=baseParts.queries, ~resolvers=queryResolvers)

    let mutationResolvers = Dict.make()
    let adminMutationEntries = ReventlessCore.AdminApi.mutationEntries(~cloner=Config.cloner)
    let adminMutationFieldNames = adminMutationEntries->Array.flatMap(entry => entry.fieldNames)
    adminMutationFieldNames->Array.forEach(field =>
      mutationResolvers->Dict.set(field, async (_root, _args, _ctx): JSON.t => JSON.Encode.string("ok"))
    )
    GraphQL_Server.registerMutations(~sdlFields=baseParts.mutations, ~resolvers=mutationResolvers)

    GraphQL_Server.start()
    MCP_Server.start()
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
