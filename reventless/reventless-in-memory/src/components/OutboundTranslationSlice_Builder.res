// In-memory OutboundTranslationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.OutboundTranslationSlice_Builder.

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

  module CoreMaker = ReventlessCore.OutboundTranslationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (Spec: Reventless.OutboundTranslationSlice.MergedSpec) => {
    include CoreMaker.Make(Spec)
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.OutboundTranslationSlice.operations> =
      ReventlessCore.Component.operations
  }
}
