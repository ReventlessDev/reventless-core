// Platform module type — abstract factory interface for platform-agnostic component assembly.
//
// Lives in reventless-spec so application plugin assembly code can depend only on
// reventless-spec. The concrete implementation in reventless-aws satisfies this type.
//
// Usage pattern:
//
//   // app/MyPlugin.res — imports reventless-spec, NOT reventless or reventless-aws
//   module Make = (Platform: ReventlessSpec.Platform.T) => {
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
      Spec: Aggregate.Spec,
      Behavior: Behavior.T with module Spec := Spec,
      EventMappings: EventMapper.Mappings with module Target := Spec,
    ) => Aggregate.T
  }

  module ReadModel: {
    module Make: (
      Spec: ReadModel.Spec,
      Mappings: Projection.Mappings with module Target := Spec,
    ) => ReadModel.T with module Spec = Spec
  }

  module ExtensionPoint: {
    module Make: (
      Spec: ExtensionPointMapping.Spec,
      Mappings: ExtensionPoint.Mappings with module Spec := Spec,
    ) => ExtensionPoint.T
  }

  module Task: {
    module Make: (Spec: Task.Spec) => Task.T with module Spec = Spec
  }

  module Counter: Counter.T

  module StateChangeSlice: {
    module Make: (Spec: StateChangeSlice.Spec) => StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec
  }

  module StateViewSlice: {
    module Make: (Spec: StateViewSlice.Spec) => StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec
  }

  module DcbEventLog: {
    module Make: (Spec: DcbEventLog.Spec) => DcbEventLog.T
      with module Spec = Spec
  }
}
