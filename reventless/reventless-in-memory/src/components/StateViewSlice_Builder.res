// In-memory StateViewSlice builder.
// Wires in-memory adapters and delegates to the core Reventless.StateViewSlice_Builder.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_InMemory.Make(
    Bus,
    EventCollectorChannel,
  )
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module QueryDbResolvers = QueryDbResolvers_GraphQL.Make(Bus)

  // InMemory api/apiRole are both unit
  module InMemoryApi = {
    let api = ()
    let apiRole = ()
  }

  module CoreMaker = Reventless.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    InMemoryApi,
  )

  module Make = (Spec: ReventlessSpec.StateViewSlice.Spec) => {
    include CoreMaker.Make(Spec)
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<Reventless.StateViewSlice.operations> =
      Reventless.Component.operations
  }
}
