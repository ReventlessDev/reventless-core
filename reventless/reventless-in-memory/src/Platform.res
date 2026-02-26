// In-memory Platform — implements ReventlessSpec.Platform.T using only in-memory data structures.
// Use in Jest tests together with TestRunner.setup() to activate Pulumi mock mode.
//
// Example:
//   TestRunner.setup()
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// The platform starts a GraphQL server on port 4000 after all components are built.
// Stop it with TestRunner.stopGraphQLServer() in afterAll.

module Make = (): ReventlessSpec.Platform.T => {
  module Bus = InMemory_Bus.Make()

  module AggregateMaker = Aggregate_Builder.Make(Bus)
  module ReadModelMaker = ReadModel_Builder.Make(Bus)
  module ExtensionPointMaker = ExtensionPoint_Builder.Make(Bus)
  module TaskMaker = Task_Builder.Make(Bus)
  module DcbEventLogMaker = DcbEventLog_Builder.Make(Bus)
  module StateViewSliceMaker = StateViewSlice_Builder.Make(Bus)

  module Aggregate = {
    module Make = (
      Spec: ReventlessSpec.Aggregate.Spec,
      Behavior: ReventlessSpec.Behavior.T with module Spec := Spec,
      EventMappings: ReventlessSpec.EventMapper.Mappings with module Target := Spec,
    ) => AggregateMaker.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: ReventlessSpec.ReadModel.Spec,
      Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
    ): (ReventlessSpec.ReadModel.T with module Spec = Spec) =>
      ReadModelMaker.Make(Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Spec: ReventlessSpec.ExtensionPointMapping.Spec,
      Mappings: ReventlessSpec.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessSpec.ExtensionPoint.T => ExtensionPointMaker.Make(Spec, Mappings)
  }

  module Task = {
    module Make = (
      Spec: ReventlessSpec.Task.Spec,
    ): (ReventlessSpec.Task.T with module Spec = Spec) => TaskMaker.Make(Spec)
  }

  module Counter = Counter_Builder.Make(Bus)

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
      and module Spec = Spec) => StateViewSliceMaker.Make(Spec)
  }

  module DcbEventLog = {
    module Make = (
      Spec: ReventlessSpec.DcbEventLog.Spec,
    ): (ReventlessSpec.DcbEventLog.T with module Spec = Spec) => DcbEventLogMaker.Make(Spec)
  }

  // Start the shared GraphQL server after all components are built.
  // In Pulumi mock mode, all Output.apply chains have fired synchronously by this point,
  // so all mutation and query resolvers are already registered in GraphQL_Server.
  let () = GraphQL_Server.start()
}
