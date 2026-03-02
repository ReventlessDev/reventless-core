// In-memory Platform — implements ReventlessInfra.Platform.T using only in-memory data structures.
// Use in Jest tests together with TestRunner.setup() to activate Pulumi mock mode.
//
// Example:
//   TestRunner.setup()
//   module Platform = Platform.Make()
//   module App = MyPlugin.Make(Platform)
//
// The platform starts a GraphQL server on port 4000 after all components are built.
// Stop it with TestRunner.stopGraphQLServer() in afterAll.

module Make = (): ReventlessInfra.Platform.T => {
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
      EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
    ) => AggregateMaker.Make(Spec, Behavior, EventMappings)
  }

  module ReadModel = {
    module Make = (
      Spec: Reventless.ReadModel.Spec,
      Mappings: Reventless.Projection.Mappings with module Target := Spec,
    ): (ReventlessInfra.ReadModel.T with module Spec = Spec) =>
      ReadModelMaker.Make(Spec, Mappings)
  }

  module ExtensionPoint = {
    module Make = (
      Spec: ReventlessInfra.ExtensionPointMapping.Spec,
      Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
    ): ReventlessInfra.ExtensionPoint.T => ExtensionPointMaker.Make(Spec, Mappings)
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
    ): (ReventlessInfra.Task.T with module Spec = Spec) => TaskMaker.Make(Spec)
  }

  module Counter = Counter_Builder.Make(Bus)

  module StateChangeSlice = {
    module Make = (
      Spec: Reventless.StateChangeSlice.Spec,
    ): (ReventlessInfra.StateChangeSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateChangeSlice_Builder.Make(Spec)
  }

  module StateViewSlice = {
    module Make = (
      Spec: Reventless.StateViewSlice.Spec,
    ): (ReventlessInfra.StateViewSlice.T
      with type dcbEvent = Spec.DcbEventLogSpec.event
      and module Spec = Spec) => StateViewSliceMaker.Make(Spec)
  }

  module DcbEventLog = {
    module Make = (
      Spec: Reventless.DcbEventLog.Spec,
    ): (ReventlessInfra.DcbEventLog.T with module Spec = Spec) => DcbEventLogMaker.Make(Spec)
  }

  module Api = {
    module Make = (
      Config: {let baseFragment: ReventlessInfra.Api.schemaFragment},
    ): ReventlessInfra.Api.T => {
      module Builder = ReventlessCore.Api_Builder.Make(GraphQL_InMemory_Adapter)
      let make = (~name, ~opts=?) =>
        Builder.make(~name, ~baseFragment=Config.baseFragment, ~opts?)
    }
  }

  // Start the shared GraphQL server after all components are built.
  // In Pulumi mock mode, all Output.apply chains have fired synchronously by this point,
  // so all mutation and query resolvers are already registered in GraphQL_Server.
  let () = GraphQL_Server.start()
}
