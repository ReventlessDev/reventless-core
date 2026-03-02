// In-memory Platform — implements Reventless.Platform.T using only in-memory data structures.
// Use in Jest tests together with TestRunner.setup() to activate Pulumi mock mode.
//
// Example:
//   TestRunner.setup()
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// The platform starts a GraphQL server on port 4000 after all components are built.
// Stop it with TestRunner.stopGraphQLServer() in afterAll.

module Make = (): Reventless.Platform.T => {
  module Bus = InMemory_Bus.Make()

  module AggregateMaker = Aggregate_Builder.Make(Bus)
  module ReadModelMaker = ReadModel_Builder.Make(Bus)
  module ExtensionPointMaker = ExtensionPoint_Builder.Make(Bus)
  module TaskMaker = Task_Builder.Make(Bus)
  module DcbEventLogMaker = DcbEventLog_Builder.Make(Bus)
  module StateViewSliceMaker = StateViewSlice_Builder.Make(Bus)

  module Aggregate = {
    module Make = (
      Spec: Reventless.Aggregate.Spec,
      Behavior: Reventless.Behavior.T with module Spec := Spec,
      EventMappings: Reventless.EventMapper.Mappings with module Target := Spec,
    ) => AggregateMaker.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (Reventless.ReadModel.T with module Spec = Spec) =>
      ReadModelMaker.Make(Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Spec: Reventless.ExtensionPointMapping.Spec,
      Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
    ): Reventless.ExtensionPoint.T => ExtensionPointMaker.Make(Spec, Mappings)
  }

  module Extension = {
    module Make = (
      Spec: Reventless.ExtensionMapping.Spec,
      Mappings: Reventless.ExtensionMapping.Mappings with module Spec := Spec,
    ): Reventless.Extension.T => ReventlessCore.Extension_Builder.Make(Spec, Mappings)
  }

  module Task = {
    module Make = (
      Spec: Reventless.Task.Spec,
    ): (Reventless.Task.T with module Spec = Spec) => TaskMaker.Make(Spec)
  }

  module Counter = Counter_Builder.Make(Bus)

  module StateChangeSlice = {
    module Make = (
      Spec: Reventless.StateChangeSlice.Spec,
    ): (Reventless.StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = {
    module Make = (
      Spec: Reventless.StateViewSlice.Spec,
    ): (Reventless.StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateViewSliceMaker.Make(Spec)
  }

  module DcbEventLog = {
    module Make = (
      Spec: Reventless.DcbEventLog.Spec,
    ): (Reventless.DcbEventLog.T with module Spec = Spec) => DcbEventLogMaker.Make(Spec)
  }

  // Start the shared GraphQL server after all components are built.
  // In Pulumi mock mode, all Output.apply chains have fired synchronously by this point,
  // so all mutation and query resolvers are already registered in GraphQL_Server.
  let () = GraphQL_Server.start()
}
