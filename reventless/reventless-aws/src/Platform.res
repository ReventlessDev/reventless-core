// Platform — concrete AWS implementation of ReventlessCore.Platform.T.
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
}): ReventlessInfra.Platform.T => {
  module Aggregate = {
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ): ReventlessInfra.Aggregate.T => Aggregate_Builder_Micro.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (ReventlessInfra.ReadModel.T with module Spec = Spec) =>
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
}
