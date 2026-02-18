// Platform — concrete AWS implementation of Reventless.Platform.T.
//
// Creates a platform instance with pre-wired AWS builders (DynamoDB, Lambda, SQS, SNS).
// Config is applied once at platform creation; component Make functors then take only
// the application-defined arguments (Spec, Behavior, Mappings).
//
// Example:
//   module Platform = Platform.Make(Config)
//   module App = MyPlugin.Make(Platform)

module Make = (Config: Config.T): Reventless.Platform.T => {
  module Aggregate = {
    module Make = (
      Spec: ReventlessSpec.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: Reventless.EventMapper.Mappings with module Target := Spec,
    ): Reventless.Aggregate.T => Aggregate_Builder_Micro.Make(Config, Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: ReventlessSpec.ReadModel_Spec.T,
      Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
    ): (Reventless.ReadModel.T with module Spec = Spec) =>
      ReadModel_Builder_Single.Make(Config, Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Spec: ReventlessSpec.ExtensionPointMapping.Spec,
      Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
    ): Reventless.ExtensionPoint.T => ExtensionPoint_Builder.Make(Spec, Mappings)
  }

  module Task = {
    module Make = (
      Spec: Reventless.Task.Spec,
    ): (Reventless.Task.T with module Spec = Spec) => Task_Builder_PerBucket.Make(Spec)
  }

  module Counter = Counter_Builder.Make(Config)

  module StateChangeSlice = {
    module Make = (
      Spec: ReventlessSpec.StateChangeSlice_Spec.T,
    ): (Reventless.StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = {
    module Make = (
      Spec: ReventlessSpec.StateViewSlice_Spec.T,
    ): (Reventless.StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateViewSlice_Builder.Make(Spec)
  }

  module DcbEventLog = {
    module Make = (
      Spec: ReventlessSpec.DcbEventLog_Spec.T,
    ): (Reventless.DcbEventLog.T with module Spec = Spec) => DcbEventLog_Builder.Make(Spec)
  }
}
