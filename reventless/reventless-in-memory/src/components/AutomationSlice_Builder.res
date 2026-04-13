// In-memory AutomationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.AutomationSlice_Builder.

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
  module Api = {
    let api = () => ()
    let apiRole = () => ()
  }

  module CoreMaker = ReventlessCore.AutomationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (Spec: Reventless.AutomationSlice.Spec) => {
    include CoreMaker.Make(Spec)
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.AutomationSlice.operations> =
      ReventlessCore.Component.operations
  }
}
