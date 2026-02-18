// Platform module type — abstract factory interface for platform-agnostic component assembly.
//
// Allows application plugin assembly code to be written as a functor over the platform,
// decoupling it from any specific infrastructure package (e.g. reventless-aws).
//
// Usage pattern:
//
//   // app/MyPlugin.res — imports reventless, NOT reventless-aws
//   module Make = (Platform: Reventless.Platform.T) => {
//     module MyAggregate = Platform.Aggregate.Make(MySpec, MyBehavior, MyMappings)
//     module MyReadModel = Platform.ReadModel.Make(MyRmSpec, MyMappings)
//     // ...
//   }
//
//   // index.res — Composition Root; the only file that imports reventless-aws
//   module Platform = ReventlessAws.Platform.Make(Config)
//   module App = MyPlugin.Make(Platform)

module type T = {
  module Aggregate: {
    module Make: (
      Spec: ReventlessSpec.Aggregate.Spec,
      Behavior: Behavior.T with module Spec := Spec,
      EventMappings: EventMapper.Mappings with module Target := Spec,
    ) => Aggregate.T
  }

  module ReadModel: {
    module Make: (
      Spec: ReventlessSpec.ReadModel_Spec.T,
      Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
    ) => ReadModel.T with module Spec = Spec
  }

  module ExtensionPoint: {
    module Make: (
      Spec: ReventlessSpec.ExtensionPointMapping.Spec,
      Mappings: ExtensionPoint.Mappings with module Spec := Spec,
    ) => ExtensionPoint.T
  }

  module Task: {
    module Make: (Spec: Task.Spec) => Task.T with module Spec = Spec
  }

  module Counter: Counter.T

  module StateChangeSlice: {
    module Make: (Spec: ReventlessSpec.StateChangeSlice_Spec.T) => StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec
  }

  module StateViewSlice: {
    module Make: (Spec: ReventlessSpec.StateViewSlice_Spec.T) => StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec
  }

  module DcbEventLog: {
    module Make: (Spec: ReventlessSpec.DcbEventLog_Spec.T) => DcbEventLog.T
      with module Spec = Spec
  }
}
