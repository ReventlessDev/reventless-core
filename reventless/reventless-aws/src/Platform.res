// Platform — concrete AWS implementation of ReventlessInfra.Platform.T.
//
// Creates a platform instance with pre-wired AWS builders (DynamoDB, Lambda, SQS, SNS).
// Config is applied once at platform creation; component Make functors then take only
// the application-defined arguments (Spec, Behavior, Mappings).
//
// Example:
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// Custom config:
//   module Platform = Platform.MakeWithConfig({let splitApi = false; let cloner = true})

// API config ref — populated during MakeWithConfig so bundled slice builders
// can access api/apiRole outside the functor constraint.
type apiConfig = {
  api: Types.AppSync.api,
  apiRole: Types.AppSync.role,
}
let apiConfigRef: ref<option<apiConfig>> = ref(None)
let getApiConfig = () =>
  apiConfigRef.contents->Option.getOrThrow(
    ~message="Platform.getApiConfig() called before MakeWithConfig",
  )

// Split API outputs — populated by makePlatform when splitApi=true.
// Access via getSplitApiOutputs() after makePlatform has been called.
type splitApiOutputs = {
  coreApi: Types.AppSync.api,
  coreRole: Types.AppSync.role,
}
let splitApiOutputsRef: ref<option<splitApiOutputs>> = ref(None)

/** Returns the core API outputs created in split mode.
    Call after `makePlatform` — returns `None` in unified mode. */
let getSplitApiOutputs = () => splitApiOutputsRef.contents

module MakeWithConfig = (
  Config: {
    let splitApi: bool
    let cloner: bool
  },
): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
  type api = Types.AppSync.api
  type role = Types.AppSync.role

  // Determine API source based on platform:stack config.
  // - Platform/monolithic mode (no config): create a real AppSync API resource.
  // - Plugin mode (config set): reference the platform's shared API via StackReference.
  let platformStackRef =
    Pulumi.Config.make(Some("platform"))
    ->Pulumi.Config.get("stack")
    ->Option.map(stack => Pulumi.StackReference.make(stack))

  let (appSyncApi, appSyncApiRole) = switch platformStackRef {
  | None =>
    AppSync_Adapter.makeApiResource(~name="api", ~opts={})
  | Some(stackRef) =>
    // Plugin mode — reconstruct phantom API/role from the platform's exported IDs.
    // Consumers only access api.id and role.arn, so other fields are unused.
    //
    // In ESM mode, Pulumi exports are inside the "default" output.
    // Try top-level "apiId" first (CJS), fall back to "default"."apiId" (ESM).
    let defaultOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("default")
    let apiIdOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("apiId")
    let apiRoleArnOutput: Pulumi.Output.t<option<string>> =
      stackRef->Pulumi.StackReference.getOutput("apiRoleArn")

    let phantomApi: Types.AppSync.api =
      (apiIdOutput, defaultOutput)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((direct, default)) => {
        let apiId = switch direct {
        | Some(id) => id
        | None =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get("apiId"))
          ->Option.flatMap(v => v->JSON.Decode.string)
          ->Option.getOrThrow
        }
        Obj.magic({"id": Pulumi.Output.make(apiId)})
      })
    let phantomRole: Types.AppSync.role =
      (apiRoleArnOutput, defaultOutput)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((direct, default)) => {
        let apiRoleArn = switch direct {
        | Some(arn) => arn
        | None =>
          default
          ->Option.flatMap(d => d->JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get("apiRoleArn"))
          ->Option.flatMap(v => v->JSON.Decode.string)
          ->Option.getOrThrow
        }
        // Derive role name from ARN (arn:aws:iam::ACCOUNT:role/NAME or .../path/NAME)
        let roleName =
          apiRoleArn
          ->String.split("/")
          ->Array.at(-1)
          ->Option.getOr(apiRoleArn)
        Obj.magic({
          "arn": Pulumi.Output.make(apiRoleArn),
          "id": Pulumi.Output.make(roleName),
          "name": Pulumi.Output.make(roleName),
        })
      })
    (phantomApi, phantomRole)
  }

  // Expose api/apiRole as Platform.T value bindings so bundled DCB slice builders
  // can access them through the platform interface.
  let api = appSyncApi
  let apiRole = appSyncApiRole

  // Also populate the module-level ref for backward compatibility.
  let () = apiConfigRef := Some({api: appSyncApi, apiRole: appSyncApiRole})

  // Local module alias so sub-builders that require {api, apiRole} can reference it.
  module ApiConfig = {
    let api = appSyncApi
    let apiRole = appSyncApiRole
  }

  module Aggregate = {
    // Non-bundled Make satisfies Platform.T but registers no entry point.
    // For working AWS deployments, use the AWS builders directly
    // (e.g., ReventlessAws.Aggregate_Builder_Single.Make) from _Aws plugin variants.
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) =>
      Aggregate_Builder_Single.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.ReadModel.T
        with module Spec = Spec
        and type api = Types.AppSync.api
        and type role = Types.AppSync.role
    ) =>
      ReadModel_Builder_Single.Make(Spec, Mappings)
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
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
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
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
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
      module Inner = ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
      include Inner
    }

    module MakeMulti = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T =>
      ExtensionPoint_Builder.Make(Spec, Mappings, {
        let publishToAggregatesQueueUrls = Dict.make()
      })
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
    ) =>
      Task_Builder_PerBucket.Make(Spec, {
        let callbackModulePaths = Dict.make()
        let publishToAggregatesQueueUrls = Dict.make()
      })
  }

  module Counter = Counter_Builder.Make(ApiConfig, {
    let specModulePath = ""
    let mappingsModulePath = ""
    let publishQueueUrl = Pulumi.Output.make("")
  })

  module StateChangeSlice = {
    module Make = (Spec: Reventless.StateChangeSlice.Spec): (
      ReventlessInfra.StateChangeSlice.T
        with module Spec = Spec
    ) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = {
    include StateViewSlice_Builder.Make(ApiConfig)
    module Bundled = StateViewSlice_Builder_Bundled.Make(ApiConfig)
  }
  module AutomationSlice = {
    include AutomationSlice_Builder.Make(ApiConfig)
    module Bundled = AutomationSlice_Builder_Bundled.Make(ApiConfig)
  }
  module OutboundTranslationSlice = {
    include OutboundTranslationSlice_Builder.Make(ApiConfig)
    module Bundled = OutboundTranslationSlice_Builder_Bundled.Make(ApiConfig)
  }
  module InboundTranslationSlice = InboundTranslationSlice_Builder.Make(ApiConfig)

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
      module Builder = ReventlessCore.Api_Builder.Make(AppSync_Adapter)
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

  // AWS platform hooks — all AWS-specific callbacks defined as a record.
  // In-memory hooks (mutationResolverHook etc.) are absent (optional = None).
  let deploySchemaPrefix = "deploy-schema:"

  let hooks: ReventlessCore.Plugin_Helpers.platformHooks = {
    // AWS uses Interstack for admin extension points — leave ref at empty dict.
    adminExtensionPoints: ref(Pulumi.Output.make(Dict.make())),
    // Platform context — populated by makePlatform/deployPlugin before plugin build.
    scheduler: ref(None),
    api: ref(None),
    apiRole: ref(None),
    inboundAppSyncResolverHook: ({runtime, fieldNames, externalInputSchemas: _, opts}) => {
      let runtimeTyped: ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts> =
        runtime->Obj.magic
      InboundTranslationResolvers_AppSync.make(
        ~api=appSyncApi,
        ~runtime=runtimeTyped,
        ~fieldNames,
        ~opts,
      )
    },
    dcbAppSyncResolverHook: ({runtime, fieldNames, tags, opts}) => {
      let runtimeTyped: ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts> =
        runtime->Obj.magic
      CommandGeneratorResolvers_AppSync.makeDcb(
        ~api=appSyncApi,
        ~runtime=runtimeTyped,
        ~fieldNames,
        ~tags,
        ~opts,
      )
    },

    // Accumulate fragments across independent plugin deployments: each plugin
    // writes its fragment to the Plugin RM table (keyed "deploy-schema:<name>")
    // at deploy time. The hook then scans for ALL deploy-schema entries and
    // stitches them together — ensuring the schema is cumulative rather than
    // overwritten by each plugin deployment.
    preResolversSchemaHook: (~name, pluginFragment) => {
      Console.log(`[preResolversSchemaHook] Pushing schema for plugin ${name} to AppSync`)

      // Read Plugin RM table name from platform StackReference.
      let pluginRmTableNameOutput: Pulumi.Output.t<option<string>> = switch platformStackRef {
      | Some(stackRef) =>
        let direct: Pulumi.Output.t<option<JSON.t>> =
          stackRef->Pulumi.StackReference.getOutput("pluginRmTableName")
        let defaultOutput: Pulumi.Output.t<option<JSON.t>> =
          stackRef->Pulumi.StackReference.getOutput("default")
        (direct, defaultOutput)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((direct, default)) =>
          switch direct->Option.flatMap(v => v->JSON.Decode.string) {
          | Some(name) => Some(name)
          | None =>
            default
            ->Option.flatMap(d => d->JSON.Decode.object)
            ->Option.flatMap(d => d->Dict.get("pluginRmTableName"))
            ->Option.flatMap(v => v->JSON.Decode.string)
          }
        )
      | None => Pulumi.Output.make(None)
      }

      pluginRmTableNameOutput->Pulumi.Output.flatMap(tableNameOpt => {
        // Write this plugin's fragment to DynamoDB, then scan all deploy-schema
        // entries to collect every deployed plugin's fragment.
        let writeAndScanFragments = () =>
          switch tableNameOpt {
          | None =>
            Console.log(
              "[preResolversSchemaHook] No pluginRmTableName — skipping fragment persistence",
            )
            Promise.resolve([pluginFragment])
          | Some(tableName) =>
            open AwsSdk.DynamoDb.DocumentClient
            // Write this plugin's fragment so subsequent plugin deployments find it.
            let deployItem =
              Dict.fromArray([
                ("id", `${deploySchemaPrefix}${name}`->JSON.Encode.string),
                ("fragment", pluginFragment.encoded->JSON.Encode.string),
              ])->JSON.Encode.object
            Console.log(
              `[preResolversSchemaHook] Writing deploy-schema entry for ${name} to ${tableName}`,
            )
            PutCommand.send(PutCommand.make({PutCommand.tableName: tableName, item: deployItem}))
            ->Promise.then(_ => {
              // Scan for all deploy-schema entries from previously deployed plugins.
              Console.log(
                `[preResolversSchemaHook] Scanning ${tableName} for deploy-schema entries`,
              )
              ScanCommand.send(
                ScanCommand.make({
                  ScanCommand.tableName: tableName,
                  filterExpression: "begins_with(#id, :prefix)",
                  expressionAttributeNames: Dict.fromArray([("#id", "id")]),
                  expressionAttributeValues: Dict.fromArray([
                    (":prefix", deploySchemaPrefix->JSON.Encode.string),
                  ]),
                }),
              )
            })
            ->Promise.then(result => {
              let items = result.items->Option.getOr([])
              let fragments = items->Array.filterMap(item => {
                try {
                  let obj = item->JSON.stringify->JSON.parseOrThrow
                  switch obj->JSON.Decode.object->Option.flatMap(d => d->Dict.get("fragment")) {
                  | Some(fragmentJson) =>
                    switch fragmentJson->JSON.Decode.string {
                    | Some(encoded) =>
                      Some({Reventless.Plugin.encoded, protocol: "graphql"})
                    | None => None
                    }
                  | None => None
                  }
                } catch {
                | _ => None
                }
              })
              Console.log(
                `[preResolversSchemaHook] Found ${fragments->Array.length->Int.toString} deploy-schema entries`,
              )
              Promise.resolve(fragments)
            })
            ->Promise.catch(err => {
              let msg =
                err
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("unknown")
              Console.log(
                `[preResolversSchemaHook] DynamoDB write/scan failed (${msg}) — using current plugin only`,
              )
              Promise.resolve([pluginFragment])
            })
          }

        appSyncApi->Pulumi.Output.flatMap(api =>
          api.id->Pulumi.Output.flatMap(apiId => {
            writeAndScanFragments()
            ->Promise.then(async allPluginFragments => {
              // In split mode, use empty base (admin is on the core API).
              // In unified mode, include admin base so the single API has everything.
              let baseFragment = if Config.splitApi {
                emptyBaseFragment
              } else {
                AppSync_Adapter.injectAwsAuthAll(
                  ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
                  ~group="Admin",
                )
              }
              let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
                ~baseFragment,
                ~pluginFragments=allPluginFragments,
              )
              Console.log(
                `[preResolversSchemaHook] Pushing schema to API ${apiId} (${allPluginFragments->Array.length->Int.toString} plugin fragments)`,
              )
              let client = AppSync_Adapter.getClient()
              let _ = await client->AppSync_Adapter.startSchemaCreation({
                apiId,
                definition: sdl->Obj.magic,
              })
              Console.log("[preResolversSchemaHook] startSchemaCreation called, waiting for ACTIVE")
              await AppSync_Adapter.waitForSchemaActive(client, apiId)
              Console.log("[preResolversSchemaHook] Schema is ACTIVE")
            })
            ->Pulumi.Output.fromPromise
          })
        )
      })
    },
    // DCB EventLog created hook — extracts DynamoDB table name for bundled DCB CommandTopic handler.
    onDcbEventLogCreated: dcbEventLogUnknown => {
      let dcbEventLog: ReventlessCore.Component.t<unit, ReventlessCore.DcbEventLog.outputs, unit> =
        Obj.magic(dcbEventLogUnknown)
      let outputs = dcbEventLog->ReventlessCore.Component.outputs
      let tableResource = outputs.resources->Array.getUnsafe(0)
      let _ = PluginRuntime_Builder.registerDcbConfig(
        ~pluginName="",
        ~dcbTableName=tableResource.name,
        (),
      )
    },
    // DCB CommandTopic created hook — extracts SQS queue URL for bundled slice builders.
    onDcbCommandTopicCreated: dcbCommandTopicUnknown => {
      let commandTopic: ReventlessCore.CommandTopic.component<unit> = Obj.magic(
        dcbCommandTopicUnknown,
      )
      let channel = commandTopic->ReventlessCore.CommandTopic_Adapter.channel
      let channelParts: Util.SQS.channelParts = Obj.magic(channel.parts)
      AutomationSliceRuntime_Builder_Single.setDcbQueueUrl(channelParts.queue.id)
    },
    // DCB slices created hook — finalize bundled slice Lambdas.
    onDcbSlicesCreated: _dcbEventLogUnknown => {
      StateViewSliceRuntime_Builder_Single.finish()
      AutomationSliceRuntime_Builder_Single.finish()
    },
    // Heartbeat EP channel hook — extracts SQS queue URL for bundled heartbeat handler.
    onHeartbeatEpChannelAvailable: remoteChannelUnknown => {
      let remoteChannel: ReventlessCore.CommandTopic_Adapter.remoteChannel = Obj.magic(
        remoteChannelUnknown,
      )
      switch remoteChannel.resources->Array.get(0) {
      | Some(resource) =>
        PluginRuntime_Builder.registerHeartbeatConfig(
          ~pluginId="",
          ~epQueueUrl=resource.id->Pulumi.Output.make,
          (),
        )
      | None =>
        Console.warn("Platform: heartbeat EP channel has no resources")
      }
    },
  }

  // Apply Plugin functor with the platform hooks, then constrain the result to Plugin.T.
  module PluginBuilderImpl = Plugin.Make({let hooks = hooks})
  module Plugin: ReventlessInfra.Plugin.T
    with type api = Types.AppSync.api
    and type role = Types.AppSync.role = {
    type api = Types.AppSync.api
    type role = Types.AppSync.role
    type component = ReventlessCore.Plugin.component
    let make = PluginBuilderImpl.make
  }

  module RuntimeEnvironment = RuntimeEnvironment.Lambda
  module EventCollectorChannel = EventCollectorChannel.SQS
  module Admin = ReventlessCore.Platform_Admin.Make(
    RuntimeEnvironment,
    EventCollectorChannel,
    QueryEngine.DynamoDb,
    ClonerRunner.Fargate,
    PluginRuntime_Builder.Make(EventCollectorChannel),
    DcbEventLogStorage.DynamoDb,
    EventTopicPublisher.DynamoDbStream,
    CommandTopicChannel.SQS_FIFO,
    {
      let silent = false
      let splitApi = Config.splitApi
      let cloner = Config.cloner
      let hooks = hooks
    },
  )

  // Admin-internal Plugin aggregate — standalone component so the PluginExtensionPoint
  // can publish commands to it and its infrastructure appears in stack outputs.
  // Use NoResolver variant — Plugin aggregate is internal (commands come via the
  // ExtensionPoint's publishToAggregates, not through AppSync mutations).
  module PluginAggregate: (
    ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
  ) = Aggregate_Builder_NoResolver.Make(
    ReventlessCore.PluginSpec,
    ReventlessCore.PluginBehavior,
    ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
  )

  // Admin-internal Plugin read model — standalone component for the Plugin QueryDb
  // (DynamoDB table) that backs queryEngine.scan(~readModelName="Plugin", ...).
  module PluginReadModelMappings: Reventless.Projection.Mappings
    with module Target := ReventlessCore.PluginReadModelSpec = {
    module M = Reventless.Projection.Mappings.Make(ReventlessCore.PluginReadModelSpec)
    module type Mapping = M.Mapping
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = ReventlessCore.PluginProjection.mappings->Obj.magic
  }

  // Use NoResolver variant — Plugin read model is internal (accessed via queryEngine,
  // not through AppSync GraphQL API). No AppSync resolvers needed.
  module PluginReadModel = ReadModel_Builder_NoResolver.Make(
    ReventlessCore.PluginReadModelSpec,
    PluginReadModelMappings,
  )

  module type PluginMaker = {
    let make: unit => Plugin.component
  }

  let makeScheduler = () => {
    let component = Scheduler.make()
    component->ReventlessCore.Component.operations
  }

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpNotSupported

  // In split mode, create a dedicated core AppSync API and push the core schema.
  // In unified mode, makePlatform is a no-op (schema stitching handled by events).
  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    Console.log(`[Platform] v${version}`)
    // Create scheduler and populate platform context refs so Plugin_Builder
    // can read them without app plugins having to pass them through.
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: appSyncApi->Obj.magic})
    hooks.apiRole := Some({val: appSyncApiRole->Obj.magic})

    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[module(PluginAggregate)],
      ~readModels=[module(PluginReadModel)],
      ~scheduler,
      ~resourceNaming=Util_ResourceNaming.operations,
      ~api=appSyncApi,
      ~apiRole=appSyncApiRole,
      ~stateChangeSlices=[],
      ~stateViewSlices=[],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )

    // Build each plugin.
    let pluginComponents = plugins->Array.map(plugin => {
      module P = unpack(plugin)
      P.make()
    })

    // Export first plugin's outputs (monolithic mode = typically single plugin).
    switch pluginComponents->Array.get(0) {
    | Some(pluginComponent) =>
      let pluginOutputs: ReventlessCore.Plugin.outputs =
        (pluginComponent->Obj.magic: ReventlessCore.Plugin.component)
        ->ReventlessCore.Component.outputs
      ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)
    | None => ()
    }

    if Config.splitApi {
      // Create a dedicated AppSync API for core administrative schema.
      let (coreApiOutput, coreRoleOutput) = AppSync_Adapter.makeApiResource(
        ~name="core-api",
        ~opts={},
      )

      // Store outputs so users can export them as stack outputs.
      splitApiOutputsRef := Some({coreApi: coreApiOutput, coreRole: coreRoleOutput})

      // Push admin schema to core API via flatMap so Pulumi tracks the async chain.
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[],
      )
      let _ = coreApiOutput->Pulumi.Output.flatMap(api =>
        api.id->Pulumi.Output.flatMap(apiId => {
          Console.log(`[makePlatform] Pushing admin schema to core-api ${apiId}`)
          let client = AppSync_Adapter.getClient()
          client
          ->AppSync_Adapter.startSchemaCreation({apiId, definition: sdl->Obj.magic})
          ->Promise.then(async _ => {
            Console.log("[makePlatform] core-api startSchemaCreation called, waiting for ACTIVE")
            await AppSync_Adapter.waitForSchemaActive(client, apiId)
            Console.log("[makePlatform] core-api schema is ACTIVE")
          })
          ->Pulumi.Output.fromPromise
        })
      )
    }
  }

  let deployPlatform = (~version) => {
    Console.log(`[Platform:deployPlatform] v${version}`)
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: appSyncApi->Obj.magic})
    hooks.apiRole := Some({val: appSyncApiRole->Obj.magic})

    // Create PluginExtensionPoint with runtime schema stitching.
    // When plugins connect/disconnect, the handler queries the Plugin read model
    // for all active schema fragments, stitches them with the admin base, and
    // pushes the combined schema to AppSync via the SDK.
    //
    // The closure captures appSyncApiId (a Pulumi Output). Pulumi serializes
    // captured Outputs into the CallbackFunction Lambda; at runtime, Output.get
    // returns the resolved string synchronously.
    let appSyncApiId = appSyncApi->Pulumi.Output.flatMap(api => api.id)

    module PluginExtensionPoint = Plugin_ExtensionPoint_Builder.MakeWithConfig({
      let updateApiSchema = Some(async (queryEngine: Reventless.QueryEngine.operations) => {
        open Reventless.QueryEngine.Filter
        let apiId = appSyncApiId->Pulumi.Output.get
        let plugins = await queryEngine.scan(
          ~readModelName="Plugin",
          ~filterConfigs=[("status", Contains, String("Connected"))],
          ~limit=1000,
        )
        let fragments = plugins->Array.filterMap(json =>
          try {
            let state = json->S.parseOrThrow(ReventlessCore.PluginReadModelSpec.stateSchema)
            state.apiSchemaFragment
          } catch {
          | _ => None
          }
        )
        // In split mode, the plugin API only has plugin schema (admin is on the core API).
        // In unified mode, stitch admin + plugins into the single shared API.
        let baseFragment = if Config.splitApi {
          emptyBaseFragment
        } else {
          AppSync_Adapter.injectAwsAuthAll(
            ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
            ~group="Admin",
          )
        }
        let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
          ~baseFragment,
          ~pluginFragments=fragments,
        )
        let _ = await AppSync_Adapter.getClient()->AppSync_Adapter.startSchemaCreation({
          apiId,
          definition: sdl->Obj.magic,
        })
      })
    })

    let admin = Admin.construct(
      ~version,
      ~extensionPoints=[module(PluginExtensionPoint)],
      ~aggregates=[module(PluginAggregate)],
      ~readModels=[module(PluginReadModel)],
      ~scheduler,
      ~resourceNaming=Util_ResourceNaming.operations,
      ~api=appSyncApi,
      ~apiRole=appSyncApiRole,
      ~stateChangeSlices=[],
      ~stateViewSlices=[],
      ~automationSlices=[],
      ~outboundTranslationSlices=[],
      ~inboundTranslationSlices=[],
    )

    // Extract admin aggregate/read-model data directly from admin outputs.
    // (Previously done via onAdminComponentsCreated hook — eliminated now that
    // Admin.construct() returns all needed data synchronously.)
    let publishToAggregatesQueueUrls = Dict.make()
    switch admin.aggregatesOutputs->Dict.get("Plugin") {
    | Some(pluginAgg) =>
      let queueUrl =
        pluginAgg.commandTopic->Pulumi.Output.flatMap(ct =>
          switch ct.resources->Array.get(0) {
          | Some(r) => r.id
          | None => Pulumi.Output.make("")
          }
        )
      publishToAggregatesQueueUrls->Dict.set("Plugin", queueUrl)
    | None => ()
    }
    // Extract Plugin RM table name as Output.t<string>.
    // IMPORTANT: Do NOT use option<Pulumi.Output.t<…>> — Pulumi Outputs use property
    // lifting, which breaks ReScript's internal option encoding (BS_PRIVATE_NESTED_SOME_NONE).
    // Instead, use Output.t<string> with a placeholder for "not available".
    let pluginReadModelTableName = switch admin.readModelsOutputs->Dict.get("Plugin") {
    | Some(pluginRm) =>
      switch pluginRm.queryDb.resources->Array.get(0) {
      | Some(r) => Some(r.name)
      | None => None
      }
    | None => None
    }
    PluginExtensionPointRuntime_Builder.registerPluginExtensionPoint(
      ~publishToAggregatesQueueUrls,
      ~pluginReadModelTableName?,
      (),
    )
    PluginRuntime_Builder.registerConfig(
      ~appSyncApiId,
      ~pluginReadModelTableName?,
      ~clonerEnabled=Config.cloner,
      (),
    )

    if Config.splitApi {
      // Split mode: create a dedicated core AppSync API for admin schema.
      // Plugin API (appSyncApi) only gets plugin schema — no admin fields.
      let (coreApiOutput, coreRoleOutput) = AppSync_Adapter.makeApiResource(
        ~name="core-api",
        ~opts={},
      )
      splitApiOutputsRef := Some({coreApi: coreApiOutput, coreRole: coreRoleOutput})

      // Push admin schema to core API via flatMap so Pulumi tracks the async chain.
      // (updateSchema uses fire-and-forget Output.apply which can miss for fresh resources.)
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[],
      )
      let _ = coreApiOutput->Pulumi.Output.flatMap(api =>
        api.id->Pulumi.Output.flatMap(apiId => {
          Console.log(`[deployPlatform] Pushing admin schema to core-api ${apiId}`)
          let client = AppSync_Adapter.getClient()
          client
          ->AppSync_Adapter.startSchemaCreation({apiId, definition: sdl->Obj.magic})
          ->Promise.then(async _ => {
            Console.log("[deployPlatform] core-api startSchemaCreation called, waiting for ACTIVE")
            await AppSync_Adapter.waitForSchemaActive(client, apiId)
            Console.log("[deployPlatform] core-api schema is ACTIVE")
          })
          ->Pulumi.Output.fromPromise
        })
      )

      // Export core API outputs so they can be consumed independently.
      Pulumi.Pulumi.export("coreApiId", coreApiOutput->Pulumi.Output.flatMap(api => api.id))
      Pulumi.Pulumi.export(
        "coreApiRoleArn",
        coreRoleOutput->Pulumi.Output.flatMap(role => role.arn),
      )
    } else {
      // Unified mode: push admin schema to the shared API.
      // Plugin schema fragments are pushed at runtime via PluginExtensionPoint.
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let _ = AppSync_Adapter.updateSchema(
        ~api=appSyncApi,
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[],
      )
    }

    // Export plugin API ID and role ARN so plugin stacks can create DataSources/Resolvers
    // against the shared (plugin) API via StackReference.
    Pulumi.Pulumi.export("apiId", appSyncApi->Pulumi.Output.flatMap(api => api.id))
    Pulumi.Pulumi.export("apiRoleArn", appSyncApiRole->Pulumi.Output.flatMap(role => role.arn))

    // Export Plugin RM table name so plugin stacks can query existing plugins
    // for cumulative schema stitching (preResolversSchemaHook).
    switch pluginReadModelTableName {
    | Some(tableName) => Pulumi.Pulumi.export("pluginRmTableName", tableName)
    | None => ()
    }

    // Export admin component outputs (same pattern as deployPlugin).
    ReventlessCore.Plugin_Helpers.exportPlatformOutputs(
      ~extensionPointsOutputs=admin.extensionPointsOutputs,
      ~aggregatesOutputs=admin.aggregatesOutputs,
      ~readModelsOutputs=admin.readModelsOutputs,
      ~dcbEventLogOutputs=admin.dcbEventLogOutputs,
      ~stateChangeSlicesOutputs=admin.stateChangeSlicesOutputs,
      ~stateViewSlicesOutputs=admin.stateViewSlicesOutputs,
      ~automationSlicesOutputs=admin.automationSlicesOutputs,
      ~outboundTranslationSlicesOutputs=admin.outboundTranslationSlicesOutputs,
      ~inboundTranslationSlicesOutputs=admin.inboundTranslationSlicesOutputs,
    )

    // Fire onPlatformDeployed hook with resolved platform metadata.
    switch ReventlessCore.Plugin_Helpers.onPlatformDeployedHook.contents {
    | Some(hook) =>
      let resolvedApiId = appSyncApi->Pulumi.Output.flatMap(api => api.id)
      let resolvedApiRoleArn = appSyncApiRole->Pulumi.Output.flatMap(role => role.arn)
      // Collect admin aggregate + read model resources.
      let adminResourcesOutput =
        admin.aggregatesOutputs
        ->Dict.valuesToArray
        ->Array.map(agg =>
          agg
          ->ReventlessCore.Aggregate.toResolvedOutputs
          ->Pulumi.Output.apply((r: ReventlessInterop.Aggregate.resolvedOutputs) =>
            Array.flat([
              r.eventLog.resources,
              r.eventLog.eventTopic.resources,
              r.commandTopic.resources,
              r.commandGenerator.resources,
            ])
          )
        )
        ->Array.concat(
          admin.readModelsOutputs
          ->Dict.valuesToArray
          ->Array.map(rm =>
            rm
            ->ReventlessCore.ReadModel.toResolvedOutputs
            ->Pulumi.Output.apply((r: ReventlessInterop.ReadModel.resolvedOutputs) =>
              r.queryDb.resources
            )
          ),
        )
        ->Pulumi.Output.all
        ->Pulumi.Output.apply(arrays => Array.flat(arrays))
      let _ =
        (resolvedApiId, resolvedApiRoleArn, adminResourcesOutput)
        ->Pulumi.Output.all3
        ->Pulumi.Output.apply(((apiId, apiRoleArn, adminResources)) => {
          let region =
            Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")->Option.getOr("unknown")
          let info: ReventlessCore.Plugin_Helpers.platformDeployedInfo = {
            name: Pulumi.Pulumi.getProjectName(),
            environment: Pulumi.Pulumi.getStackName(),
            region,
            apiId,
            apiRoleArn,
            splitApiMode: Config.splitApi,
            adminResources,
          }
          hook(info)
        })
    | None => ()
    }
  }

  let deployPlugin = (~version, ~plugin: module(PluginMaker)) => {
    Console.log(`[Platform:deployPlugin] v${version}`)
    // Each plugin stack creates its own scheduler (closures can't cross stacks).
    let scheduler = makeScheduler()
    hooks.scheduler := Some(scheduler)
    hooks.api := Some({val: appSyncApi->Obj.magic})
    hooks.apiRole := Some({val: appSyncApiRole->Obj.magic})

    module P = unpack(plugin)
    let pluginComponent = P.make()

    // Export interop metadata for cross-stack consumption.
    Pulumi.Pulumi.export("_interopMeta", ReventlessCore.Plugin_Helpers.getInteropMeta())

    // Export plugin outputs (plugin, tasks, eventMappers, extensionPoints) for cross-stack access.
    // Obj.magic bridges the nominal type gap between AWS Plugin.component and
    // ReventlessCore.Component.t — they are structurally identical.
    let pluginOutputs: ReventlessCore.Plugin.outputs =
      (pluginComponent->Obj.magic: ReventlessCore.Plugin.component)->ReventlessCore.Component.outputs
    ReventlessCore.Plugin_Helpers.exportPluginOutputs(pluginOutputs)

    pluginOutputs
  }
}

// Default platform — split API, no cloner.
module Make = (): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
  include MakeWithConfig({
    let splitApi = true
    let cloner = false
  })
}
