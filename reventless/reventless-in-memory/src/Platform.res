// In-memory Platform — implements ReventlessInfra.Platform.T using only in-memory data structures.
// Use in Jest tests together with TestRunner.setup() to activate Pulumi mock mode.
//
// Example:
//   TestRunner.setup()
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// The platform starts a GraphQL server on port 4000 after all components are built.
// Stop it with TestRunner.stopGraphQLServer() in afterAll.

// Silent-configurable platform — set silent=true to suppress diagnostic warnings in tests.
// Usage: module Platform = Platform.MakeWithConfig({let silent = true})
module MakeWithConfig = (
  Config: {
    let silent: bool
  },
): (ReventlessInfra.Platform.T with type api = unit and type role = unit) => {
  type api = unit
  type role = unit

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
  }

  module AutomationSlice = {
    module Make = (Spec: Reventless.AutomationSlice.Spec): (
      ReventlessInfra.AutomationSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => AutomationSliceMaker.Make(Spec)
  }

  module OutboundTranslationSlice = {
    module Make = (Spec: Reventless.OutboundTranslationSlice.Spec): (
      ReventlessInfra.OutboundTranslationSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => OutboundTranslationSliceMaker.Make(Spec)
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

  module Api = {
    module Make = (
      Config: {
        let baseFragment: ReventlessInfra.Api.schemaFragment
      },
    ): ReventlessInfra.Api.T => {
      module Builder = ReventlessCore.Api_Builder.Make(GraphQL_InMemory_Adapter)
      let make = (~name, ~opts=?) => Builder.make(~name, ~baseFragment=Config.baseFragment, ~opts?)
    }
  }

  // Set the DCB mutation resolver hook so Plugin_Builder.construct() registers
  // GraphQL resolvers for each StateChangeSlice during plugin construction.
  let () = ReventlessCore.Plugin_Helpers.dcbMutationResolverHook.contents = Some(
    DcbCommandTopicResolvers_GraphQL.register,
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

  // Set the aggregate mutation resolver hook so Plugin_Builder.construct() registers
  // GraphQL SDL + resolver stubs for each aggregate during plugin construction.
  // The real generateCommand handler is bound later when Output.apply chains fire.
  let () = ReventlessCore.Plugin_Helpers.aggregateMutationResolverHook.contents = Some(
    CommandGeneratorResolvers_GraphQL.register,
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
          let result = await resolver(JSON.Encode.null, args)
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
          let pathPart = (uri->String.split("?"))->Array.getUnsafe(0)
          let segments = pathPart->String.split("/")
          let entityId = segments->Array.at(-1)->Option.getOr("")
          let (limit, after) = {
            let parts = uri->String.split("?")
            switch parts->Array.get(1) {
            | None => (None, None)
            | Some(qs) =>
              let params = Dict.make()
              qs->String.split("&")->Array.forEach(param => {
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
                  (
                    "nextAfter",
                    nextAfter->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
                  ),
                ])->JSON.Encode.object,
              ),
            ])->JSON.Encode.object

          // Apply pagination: skip events before "after" position, limit count
          let paginate = (events: array<JSON.t>, getPosition: JSON.t => option<string>) => {
            let filtered = switch after {
            | Some(afterPos) =>
              let idx =
                events->Array.findIndex(e =>
                  getPosition(e)->Option.mapOr(false, p => p > afterPos)
                )
              if idx >= 0 {
                events->Array.slice(~start=idx, ~end=events->Array.length)
              } else {
                []
              }
            | None => events
            }
            let (limited, hasMore) = switch limit {
            | Some(n) when filtered->Array.length > n =>
              (filtered->Array.slice(~start=0, ~end=n), true)
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
                  ->Dict.get("sequenceNr")
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
                  result.events->Array.filter(e =>
                    e.tags->Array.some(tag => tag.value == entityId)
                  )
                } else {
                  result.events
                }
                let serialized =
                  filtered->Array.map(e =>
                    Dict.fromArray([
                      ("position", JSON.Encode.string(e.position)),
                      ("eventType", JSON.Encode.string(e.eventType)),
                      ("data", e.data),
                      (
                        "tags",
                        e.tags
                        ->Array.map(t =>
                          Dict.fromArray([
                            ("key", JSON.Encode.string(t.key)),
                            ("value", JSON.Encode.string(t.value)),
                          ])->JSON.Encode.object
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
              | None =>
                makePaginatedResponse(~events=[], ~hasMore=false, ~nextAfter=None)
              }
            }
          | None => makePaginatedResponse(~events=[], ~hasMore=false, ~nextAfter=None)
          }
        },
      )
    },
  )

  module PluginMaker = Plugin_Builder.Make(Bus)
  // Obj.magic: ReventlessCore.Plugin.T.make is structurally identical to
  // ReventlessInfra.Plugin.T.make — only the DcbSpec module-type path differs nominally.
  module Plugin: ReventlessInfra.Plugin.T
    with type api = unit
    and type role = unit
    and type component = ReventlessCore.Plugin.component = {
    type api = unit
    type role = unit
    type component = ReventlessCore.Plugin.component
    let make = Obj.magic(PluginMaker.make)
  }

  module CoreMaker = Core_Builder.Make(Bus)
  module Core: ReventlessInfra.Core.T with type api = unit and type role = unit = {
    type api = unit
    type role = unit
    type component = ReventlessCore.Core.component
    let make = CoreMaker.make
  }

  let makeScheduler = () => {
    module SP = ScheduledPublisher_InMemory.Make(Bus)
    module S = ReventlessCore.Scheduler_Builder.Make(SP)
    let component = S.make()
    component->ReventlessCore.Component.operations
  }

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpSupported

  let makePlatform = (~api as _, ~core as _, ~plugins) => {
    // Create an in-memory Plugin QueryDb in the Bus.
    // This mirrors what QueryDbStorage_InMemory does for user read models,
    // providing the runtime store that backs plugin/everyPlugin queries.
    let pluginQueryDbName = ReventlessCore.PluginReadModelSpec.name
    let store: ref<dict<array<JSON.t>>> = ref(Dict.make())
    let allItems: ref<array<JSON.t>> = ref([])
    let syncAll = () => {
      allItems.contents = store.contents->Dict.valuesToArray->Array.flatMap(v => v)
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
        (outputs.id, outputs.version, outputs.eventCollector, outputs.extensionPoints, outputs.extensions)
        ->Pulumi.Output.all5
        ->Pulumi.Output.apply(((id, version, eventCollector, extensionPoints, extensions)) => {
          let state: ReventlessCore.PluginReadModelSpec.state = {
            name: id->String.split("@")->Array.get(0)->Option.getOr(id),
            version,
            eventCollector: eventCollector.name,
            extensionPoints: extensionPoints
              ->Dict.toArray
              ->Array.map(((epName, ep: ReventlessInfra.ExtensionPoint.outputs)) => {
                Reventless.Plugin.name: epName,
                commandTopic: epName,
                eventTopic: ep.name,
              }),
            extensionPointNames: extensionPoints->Dict.keysToArray,
            extensionNames: extensions->Dict.keysToArray,
            extensions: extensions
              ->Dict.toArray
              ->Array.map(((_, ext: ReventlessInfra.Extension.outputs)) => {
                Reventless.Plugin.name: ext.name,
                extensionPointName: ext.extensionPointName,
              }),
            status: Connected,
            statusChange: {at: Date.make()->Date.toISOString, by: "in-memory"},
            apiSchemaFragment: None,
          }
          let entry = state->S.reverseConvertToJsonOrThrow(ReventlessCore.PluginReadModelSpec.stateSchema)
          let _ = pluginOps.save(id, entry, Any, None)
        })
    })

    // Register the core Plugin aggregate's types/queries/mutations from the base fragment
    // into the GraphQL server. User plugin schemas are registered via hooks during
    // Plugin_Builder.construct(), but the core's own schema needs explicit registration.
    let baseParts = ReventlessCore.GraphQL_Stitcher.decode(ReventlessCore.CoreApi.baseFragment)
    GraphQL_Server.registerTypes(~sdlTypes=baseParts.types)

    // Resolvers for the core Plugin queries — backed by Bus Plugin QueryDb.
    let queryResolvers = Dict.make()
    queryResolvers->Dict.set("Core_Plugin", (async (_root, args): JSON.t => {
      let id =
        args
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get("id"))
        ->Option.flatMap(JSON.Decode.string)
        ->Option.getOr("")
      switch Bus.getQueryDb(pluginQueryDbName) {
      | Some(ops) =>
        let items =
          await ops.loadStream(id)
          ->Stream.runCollect
          ->Effect.catchAll(_ => Effect.succeed([]))
          ->Effect.runPromise
        items->Array.get(0)->Option.getOr(JSON.Encode.null)
      | None => JSON.Encode.null
      }
    }))
    queryResolvers->Dict.set("Core_Plugins", (async (_root, _args): JSON.t => {
      let items = switch Bus.getQueryDbScan(pluginQueryDbName) {
      | Some(scanAll) => scanAll()
      | None => []
      }
      Dict.fromArray([
        ("nextToken", JSON.Encode.null),
        ("scannedCount", JSON.Encode.int(items->Array.length)),
        ("items", items->JSON.Encode.array),
      ])->JSON.Encode.object
    }))
    GraphQL_Server.registerQueries(
      ~sdlFields=baseParts.queries,
      ~resolvers=queryResolvers,
    )

    // Stub resolvers for core mutations (Plugin_Activate, Plugin_Deactivate, clone).
    // These are no-ops in the in-memory platform — the real logic runs in AWS Lambda.
    let mutationResolvers = Dict.make()
    mutationResolvers->Dict.set("Core_Plugin_Activate", (async (_root, _args): JSON.t =>
      JSON.Encode.string("ok")
    ))
    mutationResolvers->Dict.set("Core_Plugin_Deactivate", (async (_root, _args): JSON.t =>
      JSON.Encode.string("ok")
    ))
    mutationResolvers->Dict.set("Core_Clone", (async (_root, _args): JSON.t =>
      JSON.Encode.string("clone not supported in-memory")
    ))
    GraphQL_Server.registerMutations(
      ~sdlFields=baseParts.mutations,
      ~resolvers=mutationResolvers,
    )

    // Register core Plugin queries and mutations as MCP resources and tools.
    let pluginQueryHandler = async (_resourceName, uri) => {
      let segments = uri->String.split("/")
      let id = segments->Array.at(-1)->Option.getOr("")
      switch Bus.getQueryDb(pluginQueryDbName) {
      | Some(ops) =>
        if id->String.length > 0 && id != "Core_Plugins" {
          let items =
            await ops.loadStream(id)
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
    MCP_Server.registerResourcesFromEntries(
      ~pluginName="Core",
      ~queryEntries=ReventlessCore.PluginBaseFragment.queryEntries,
      ~queryHandler=pluginQueryHandler,
    )

    // Register core mutations as MCP tools using the same entry-based path as plugins.
    MCP_Server.registerToolsFromEntries(
      ~pluginName="Core",
      ~mutationEntries=ReventlessCore.CoreApi.mutationEntries,
      ~commandHandler=async (toolName, args) => {
        switch GraphQL_Server.getMutationResolver(toolName) {
        | Some(resolver) =>
          let result = await resolver(JSON.Encode.null, args)
          switch result->JSON.Decode.string {
          | Some(s) => s
          | None => result->JSON.stringify
          }
        | None => `error: no handler found for tool ${toolName}`
        }
      },
    )

    // Start the shared GraphQL server after all plugins have been built.
    // All Output.apply chains have fired synchronously by this point,
    // so all mutation and query resolvers are already registered in GraphQL_Server.
    GraphQL_Server.start()
    // Start the MCP server alongside GraphQL (shared lifecycle).
    MCP_Server.start()
  }
}

// Default platform — diagnostic warnings enabled.
module Make = (): (ReventlessInfra.Platform.T with type api = unit and type role = unit) => {
  include MakeWithConfig({
    let silent = false
  })
}
