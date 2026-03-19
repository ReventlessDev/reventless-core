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

  // Local module alias so sub-builders that require {api, apiRole} can reference it.
  module ApiConfig = {
    let api = appSyncApi
    let apiRole = appSyncApiRole
  }

  module Aggregate = {
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) => Aggregate_Builder_Micro.Make(Spec, Behavior, EventMappings)

    module MakeBundled = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
      Config: Aggregate_Builder_Single_Bundled.BundledConfig,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) => Aggregate_Builder_Single_Bundled.Make(Spec, Behavior, EventMappings, Config)

    module MakeBundledPerAggregate = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
      Config: Aggregate_Builder_PerAggregate_Bundled.BundledConfig,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) => Aggregate_Builder_PerAggregate_Bundled.Make(Spec, Behavior, EventMappings, Config)

    module MakeBundledMicro = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
      Config: Aggregate_Builder_Micro_Bundled.BundledConfig,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) => Aggregate_Builder_Micro_Bundled.Make(Spec, Behavior, EventMappings, Config)
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
    ) => ReadModel_Builder_Single.Make(Spec, Mappings)

    module MakeBundled = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
      Config: ReadModel_Builder_Single_Bundled.BundledConfig,
    ): (
      ReventlessInfra.ReadModel.T
        with module Spec = Spec
        and type api = Types.AppSync.api
        and type role = Types.AppSync.role
    ) => ReadModel_Builder_Single_Bundled.Make(Spec, Mappings, Config)
  }

  module ExtensionPoint = {
    module Make = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T => ExtensionPoint_Builder.Make(Spec, Mappings)

    module MakeBundled = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
      Config: ExtensionPoint_Builder_Bundled.BundledConfig,
    ): ReventlessInfra.ExtensionPoint.T => ExtensionPoint_Builder_Bundled.Make(Spec, Mappings, Config)
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
    ) => Task_Builder_PerBucket.Make(Spec)
  }

  module Counter = Counter_Builder.Make(ApiConfig)

  module StateChangeSlice = {
    module Make = (Spec: Reventless.StateChangeSlice.Spec): (
      ReventlessInfra.StateChangeSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = StateViewSlice_Builder.Make(ApiConfig)
  module AutomationSlice = AutomationSlice_Builder.Make(ApiConfig)
  module OutboundTranslationSlice = OutboundTranslationSlice_Builder.Make(ApiConfig)
  module InboundTranslationSlice = InboundTranslationSlice_Builder.Make(ApiConfig)

  module DcbEventLog = {
    module Make = (Spec: Reventless.DcbEventLog.Spec): (
      ReventlessInfra.DcbEventLog.T with module Spec = Spec
    ) => DcbEventLog_Builder.Make(Spec)
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

  // Set the InboundTranslationSlice AppSync resolver hook so Plugin_Builder
  // creates AppSync DataSource + Resolvers pointing to the shared DCB Lambda.
  let () = ReventlessCore.Plugin_Helpers.inboundAppSyncResolverHook.contents = Some(
    ({runtime, fieldNames, externalInputSchemas: _, opts}) => {
      let runtimeTyped: ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts> =
        runtime->Obj.magic
      InboundTranslationResolvers_AppSync.make(
        ~api=appSyncApi,
        ~runtime=runtimeTyped,
        ~fieldNames,
        ~opts,
      )
    },
  )

  // Set the DCB StateChangeSlice AppSync resolver hook so Dcb_Builder creates
  // AppSync DataSource + Resolvers for each StateChangeSlice mutation, pointing
  // to the shared DCB CommandTopic Lambda.
  let () = ReventlessCore.Plugin_Helpers.dcbAppSyncResolverHook.contents = Some(
    ({runtime, fieldNames, tags, opts}) => {
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
  )

  // Set the pre-resolvers schema push hook so plugin stacks push their
  // schema fragment to AppSync before QueryDb resolvers are created.
  // Without this, resolvers reference types that don't exist in the schema yet.
  // Uses Output.flatMap to ensure the API call completes before resolvers are created.
  let () = ReventlessCore.Plugin_Helpers.preResolversSchemaHook.contents = Some(
    pluginFragment => {
      Console.log("[preResolversSchemaHook] Pushing plugin schema fragment to AppSync")
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
        ~baseFragment=adminBaseFragment,
        ~pluginFragments=[pluginFragment],
      )
      appSyncApi->Pulumi.Output.flatMap(api =>
        api.id->Pulumi.Output.flatMap(apiId => {
          Console.log(`[preResolversSchemaHook] Calling startSchemaCreation for API ${apiId}`)
          let definition: unknown = sdl->Obj.magic
          let client = AppSync_Adapter.getClient()
          client
          ->AppSync_Adapter.startSchemaCreation({apiId, definition})
          ->Promise.then(async _ => {
            Console.log("[preResolversSchemaHook] startSchemaCreation called, waiting for ACTIVE")
            await AppSync_Adapter.waitForSchemaActive(client, apiId)
            Console.log("[preResolversSchemaHook] Schema is ACTIVE")
          })
          ->Pulumi.Output.fromPromise
        })
      )
    },
  )

  // Alias before defining module Plugin to avoid self-reference.
  module PluginBuilder = Plugin
  module Plugin: ReventlessInfra.Plugin.T
    with type api = Types.AppSync.api
    and type role = Types.AppSync.role = {
    type api = Types.AppSync.api
    type role = Types.AppSync.role
    type component = ReventlessCore.Plugin.component
    let make = PluginBuilder.make
  }

  module RuntimeEnvironment = RuntimeEnvironment.Lambda
  module EventCollectorChannel = EventCollectorChannel.SQS
  module Admin = ReventlessCore.Platform_Admin.Make(
    RuntimeEnvironment,
    EventCollectorChannel,
    QueryEngine.DynamoDb,
    ClonerRunner.Fargate,
    PluginRuntime_Builder_Bundled.Make(EventCollectorChannel),
    DcbEventLogStorage.DynamoDb,
    EventTopicPublisher.DynamoDbStream,
    CommandTopicChannel.SQS_FIFO,
    {
      let silent = false
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
    let component = Scheduler.make()
    component->ReventlessCore.Component.operations
  }

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpNotSupported

  // In split mode, create a dedicated core AppSync API and push the core schema.
  // In unified mode, makePlatform is a no-op (schema stitching handled by events).
  let makePlatform = (~version, ~plugins: array<module(PluginMaker)>) => {
    Console.log(`[Platform] v${version}`)
    // Create scheduler and admin components internally.
    let scheduler = makeScheduler()
    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[],
      ~aggregates=[],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=Util_ResourceNaming.operations,
      ~api=appSyncApi,
      ~apiRole=appSyncApiRole,
      ~dcbSpec=None,
    )

    // Build each plugin using the shared scheduler.
    let _plugins = plugins->Array.map(plugin => {
      module P = unpack(plugin)
      P.make(~scheduler, ~api=appSyncApi, ~apiRole=appSyncApiRole)
    })

    if Config.splitApi {
      // Create a dedicated AppSync API for core administrative schema.
      let (coreApiOutput, coreRoleOutput) = AppSync_Adapter.makeApiResource(
        ~name="core-api",
        ~opts={},
      )

      // Store outputs so users can export them as stack outputs.
      splitApiOutputsRef := Some({coreApi: coreApiOutput, coreRole: coreRoleOutput})

      // Push the admin schema (base fragment only, no plugin fragments).
      // This is a one-time operation — admin schema is static.
      let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
        ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
        ~group="Admin",
      )
      let _ = coreApiOutput->Pulumi.Output.apply(coreApi => {
        let _ = AppSync_Adapter.updateSchema(
          ~api=Pulumi.Output.make(coreApi),
          ~baseFragment=adminBaseFragment,
          ~pluginFragments=[],
        )
      })
    }
  }

  // Helper: serialize admin extension points as a stack output for cross-stack consumption.
  let exportAdminExtensionPoints = () => {
    switch ReventlessCore.Plugin_Helpers.localAdminExtensionPoints.contents {
    | Some(adminEPs) =>
      let serialized =
        adminEPs->Pulumi.Output.flatMap(eps =>
          eps
          ->Dict.toArray
          ->Array.map(((name, ep)) =>
            ep
            ->ReventlessCore.ExtensionPoint.toResolvedOutputs
            ->Pulumi.Output.apply(resolved => (name, resolved->S.reverseConvertToJsonOrThrow(
              ReventlessInterop.ExtensionPoint.resolvedOutputsSchema,
            )))
          )
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray->JSON.Encode.object)
        )
      Pulumi.Pulumi.export("extensionPoints", serialized)
    | None => ()
    }
  }

  let deployPlatform = (~version) => {
    Console.log(`[Platform:deployPlatform] v${version}`)
    let scheduler = makeScheduler()

    // Create PluginExtensionPoint with runtime schema stitching.
    // When plugins connect/disconnect, the handler queries the Plugin read model
    // for all active schema fragments, stitches them with the admin base, and
    // pushes the combined schema to AppSync via the SDK.
    //
    // The closure captures appSyncApiId (a Pulumi Output). Pulumi serializes
    // captured Outputs into the CallbackFunction Lambda; at runtime, Output.get
    // returns the resolved string synchronously.
    let appSyncApiId = appSyncApi->Pulumi.Output.flatMap(api => api.id)

    // Register bundled Admin EventCollector config with available infrastructure values.
    // Values that aren't available in Platform-only deployment use defaults (NOT_AVAILABLE).
    PluginRuntime_Builder_Bundled.registerConfig(
      ~appSyncApiId=appSyncApiId,
      ~clonerEnabled=Config.cloner,
      (),
    )

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
        let adminBase = AppSync_Adapter.injectAwsAuthAll(
          ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
          ~group="Admin",
        )
        let sdl = ReventlessCore.GraphQL_Stitcher.stitch(
          ~baseFragment=adminBase,
          ~pluginFragments=fragments,
        )
        let _ = await AppSync_Adapter.getClient()->AppSync_Adapter.startSchemaCreation({
          apiId,
          definition: sdl->Obj.magic,
        })
      })
    })

    let _admin = Admin.construct(
      ~version,
      ~extensionPoints=[module(PluginExtensionPoint)],
      ~aggregates=[],
      ~readModels=[],
      ~scheduler,
      ~resourceNaming=Util_ResourceNaming.operations,
      ~api=appSyncApi,
      ~apiRole=appSyncApiRole,
      ~dcbSpec=None,
    )

    // Push admin schema to the shared API. In per-plugin deployment there is one
    // API — plugin schema fragments are pushed at runtime via PluginExtensionPoint.
    let adminBaseFragment = AppSync_Adapter.injectAwsAuthAll(
      ReventlessCore.AdminApi.baseFragment(~cloner=Config.cloner),
      ~group="Admin",
    )
    let _ = AppSync_Adapter.updateSchema(
      ~api=appSyncApi,
      ~baseFragment=adminBaseFragment,
      ~pluginFragments=[],
    )

    // Export API ID and role ARN so plugin stacks can create DataSources/Resolvers
    // against the shared API via StackReference.
    Pulumi.Pulumi.export("apiId", appSyncApi->Pulumi.Output.flatMap(api => api.id))
    Pulumi.Pulumi.export("apiRoleArn", appSyncApiRole->Pulumi.Output.flatMap(role => role.arn))

    // Export admin extension points for plugin stacks to consume.
    exportAdminExtensionPoints()
  }

  let deployPlugin = (~version, ~plugin: module(PluginMaker)) => {
    Console.log(`[Platform:deployPlugin] v${version}`)
    // Each plugin stack creates its own scheduler (closures can't cross stacks).
    let scheduler = makeScheduler()

    module P = unpack(plugin)
    let _plugin = P.make(~scheduler, ~api=appSyncApi, ~apiRole=appSyncApiRole)

    // Export interop metadata for cross-stack consumption.
    Pulumi.Pulumi.export("_interopMeta", ReventlessCore.Plugin_Helpers.getInteropMeta())
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
