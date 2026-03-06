// Platform — concrete AWS implementation of ReventlessInfra.Platform.T.
//
// Creates a platform instance with pre-wired AWS builders (DynamoDB, Lambda, SQS, SNS).
// Config is applied once at platform creation; component Make functors then take only
// the application-defined arguments (Spec, Behavior, Mappings).
//
// Example:
//   module Platform = Platform.Make(Config)
//   module App = MyPlugin.Make(Platform)

module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}): (ReventlessInfra.Platform.T
  with type api = Types.AppSync.api
  and type role = Types.AppSync.role
) => {
  type api = Types.AppSync.api
  type role = Types.AppSync.role

  // Alias the functor parameter before module Api shadows it below.
  let appSyncApi = Api.api

  module Aggregate = {
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): (ReventlessInfra.Aggregate.T with type api = Types.AppSync.api) =>
      Aggregate_Builder_Micro.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (ReventlessInfra.ReadModel.T
      with module Spec = Spec
      and type api = Types.AppSync.api
      and type role = Types.AppSync.role) =>
      ReadModel_Builder_Single.Make(Spec, Mappings)
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
    module Make = (
      Spec: ReventlessInfra.Task.Spec,
    ): (ReventlessInfra.Task.T with module Spec = Spec) => Task_Builder_PerBucket.Make(Spec)
  }

  module Counter = Counter_Builder.Make(Api)

  module StateChangeSlice = {
    module Make = (
      Spec: Reventless.StateChangeSlice.Spec,
    ): (ReventlessInfra.StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = StateViewSlice_Builder.Make(Api)
  module AutomationSlice = AutomationSlice_Builder.Make(Api)
  module OutboundTranslationSlice = OutboundTranslationSlice_Builder.Make(Api)
  module InboundTranslationSlice = InboundTranslationSlice_Builder.Make(Api)

  module DcbEventLog = {
    module Make = (
      Spec: Reventless.DcbEventLog.Spec,
    ): (ReventlessInfra.DcbEventLog.T with module Spec = Spec) => DcbEventLog_Builder.Make(Spec)
  }

  module Api = {
    module Make = (
      Config: {let baseFragment: ReventlessInfra.Api.schemaFragment},
    ): ReventlessInfra.Api.T => {
      module Builder = ReventlessCore.Api_Builder.Make(AppSync_Adapter)
      let make = (~name, ~opts=?) =>
        Builder.make(~name, ~baseFragment=Config.baseFragment, ~opts?)
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
  // Obj.magic: ReventlessCore.Plugin.T.make is structurally identical to
  // ReventlessInfra.Plugin.T.make — only the DcbSpec module-type path differs nominally.
  module Plugin: (ReventlessInfra.Plugin.T
    with type api = Types.AppSync.api
    and type role = Types.AppSync.role
  ) = {
    type api = Types.AppSync.api
    type role = Types.AppSync.role
    type component = ReventlessCore.Plugin.component
    let make = Obj.magic(PluginBuilder.make)
  }

  module Core: (ReventlessInfra.Core.T
    with type api = Types.AppSync.api
    and type role = Types.AppSync.role
  ) = {
    type api = Types.AppSync.api
    type role = Types.AppSync.role
    type component = ReventlessCore.Core.component
    let make = Core_Builder.make
  }

  let makeScheduler = () => {
    let component = Scheduler.make()
    component->ReventlessCore.Component.operations
  }

  type mcpSupported = | @as(true) McpSupported | @as(false) McpNotSupported
  let mcpSupported = McpNotSupported

  let makePlatform = (~api as _, ~core as _, ~plugins as _) => {
    // Schema stitching is handled by the event system (ConnectPluginExtension).
    // Stack exports are set by user entry-point code.
    ()
  }
}
