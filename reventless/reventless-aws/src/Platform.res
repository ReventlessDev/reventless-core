// Platform — concrete AWS implementation of ReventlessCore.Platform.T.
//
// Creates a platform instance with pre-wired AWS builders (DynamoDB, Lambda, SQS, SNS).
// Config is applied once at platform creation; component Make functors then take only
// the application-defined arguments (Spec, Behavior, Mappings).
//
// Example:
//   module Platform = Platform.Make(Config)
//   module App = MyPlugin.Make(Platform)

module Make = (ApiValues: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
}): Reventless.Platform.T => {
  module Aggregate = {
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: Reventless.EventMapper.Mappings with module Target := Spec,
    ): Reventless.Aggregate.T => Aggregate_Builder_Micro.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (Reventless.ReadModel.T with module Spec = Spec) =>
      ReadModel_Builder_Single.Make(Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Spec: Reventless.ExtensionPointMapping.Spec,
      Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
    ): Reventless.ExtensionPoint.T => ExtensionPoint_Builder.Make(Spec, Mappings)
  }

  module Task = {
    module Make = (
      Spec: Reventless.Task.Spec,
    ): (Reventless.Task.T with module Spec = Spec) => Task_Builder_PerBucket.Make(Spec)
  }

  module Counter = Counter_Builder.Make(ApiValues)

  module StateChangeSlice = {
    module Make = (
      Spec: Reventless.StateChangeSlice.Spec,
    ): (Reventless.StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = StateViewSlice_Builder.Make(ApiValues)

  module DcbEventLog = {
    module Make = (
      Spec: Reventless.DcbEventLog.Spec,
    ): (Reventless.DcbEventLog.T with module Spec = Spec) => DcbEventLog_Builder.Make(Spec)
  }
}
