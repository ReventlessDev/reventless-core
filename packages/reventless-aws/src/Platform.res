// Platform — concrete AWS implementation of Reventless.Platform.T.
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
}): ReventlessSpec.Platform.T => {
  module Aggregate = {
    module Make = (
      Spec: ReventlessSpec.Aggregate.Spec,
      Behavior: ReventlessSpec.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessSpec.EventMapper.Mappings with module Target := Spec,
    ): ReventlessSpec.Aggregate.T => Aggregate_Builder_Micro.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: ReventlessSpec.ReadModel.Spec,
      Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
    ): (ReventlessSpec.ReadModel.T with module Spec = Spec) =>
      ReadModel_Builder_Single.Make(Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Spec: ReventlessSpec.ExtensionPointMapping.Spec,
      Mappings: ReventlessSpec.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessSpec.ExtensionPoint.T => ExtensionPoint_Builder.Make(Spec, Mappings)
  }

  module Task = {
    module Make = (
      Spec: ReventlessSpec.Task.Spec,
    ): (ReventlessSpec.Task.T with module Spec = Spec) => Task_Builder_PerBucket.Make(Spec)
  }

  module Counter = Counter_Builder.Make(ApiValues)

  module StateChangeSlice = {
    module Make = (
      Spec: ReventlessSpec.StateChangeSlice.Spec,
    ): (ReventlessSpec.StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = {
    module Make = (
      Spec: ReventlessSpec.StateViewSlice.Spec,
    ): (ReventlessSpec.StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateViewSlice_Builder.Make(Spec)
  }

  module DcbEventLog = {
    module Make = (
      Spec: ReventlessSpec.DcbEventLog.Spec,
    ): (ReventlessSpec.DcbEventLog.T with module Spec = Spec) => DcbEventLog_Builder.Make(Spec)
  }
}
