// Platform — concrete AWS implementation of ReventlessInfra.Platform.T.
//
// Creates a platform instance with pre-wired AWS builders (DynamoDB, Lambda, SQS, SNS).
// Config is applied once at platform creation; component Make functors then take only
// the application-defined arguments (Spec, Behavior, Mappings).
//
// Example:
//   module Platform = Platform.Make({let api = ...; let apiRole = ...})
//   module App = MyPlugin.Make(Platform)
//
// Split API mode:
//   module Platform = Platform.MakeWithConfig(
//     {let api = ...; let apiRole = ...},
//     {let splitApi = true},
//   )
// When splitApi=true, the plugin Api.Make creates a plugin-only AppSync API
// (no core schema). A separate core AppSync API is created internally and
// its schema is pushed in makePlatform.

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
  Api: {
    let api: Types.AppSync.api
    let apiRole: Types.AppSync.role
  },
  Config: {
    let splitApi: bool
    let cloner: bool
  },
): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
  type api = Types.AppSync.api
  type role = Types.AppSync.role

  // Alias the functor parameters before module Api shadows them below.
  let appSyncApi = Api.api
  let appSyncApiRole = Api.apiRole

  module Aggregate = {
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (
      ReventlessInfra.Aggregate.T with type api = Types.AppSync.api
    ) => Aggregate_Builder_Micro.Make(Spec, Behavior, EventMappings)
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
  }

  module ExtensionPoint = {
    module Make = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T => ExtensionPoint_Builder.Make(Spec, Mappings)
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

  module Counter = Counter_Builder.Make(Api)

  module StateChangeSlice = {
    module Make = (Spec: Reventless.StateChangeSlice.Spec): (
      ReventlessInfra.StateChangeSlice.T
        with type dcbEvent = Spec.DcbEventLogSpec.event
        and module Spec = Spec
    ) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = StateViewSlice_Builder.Make(Api)
  module AutomationSlice = AutomationSlice_Builder.Make(Api)
  module OutboundTranslationSlice = OutboundTranslationSlice_Builder.Make(Api)
  module InboundTranslationSlice = InboundTranslationSlice_Builder.Make(Api)

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
    ReventlessCore.PluginRuntime_Builder_Micro.Make(
      RuntimeEnvironment_Lambda,
      EventCollectorChannel,
    ),
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
}

// Default platform — unified API (no split).
module Make = (
  Api: {
    let api: Types.AppSync.api
    let apiRole: Types.AppSync.role
  },
): (
  ReventlessInfra.Platform.T with type api = Types.AppSync.api and type role = Types.AppSync.role
) => {
  include MakeWithConfig(
    Api,
    {
      let splitApi = true
      let cloner = false
    },
  )
}
