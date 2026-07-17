// In-memory OutboundTranslationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.OutboundTranslationSlice_Builder.

module Make = (Bus: LocalBus.T) => {
  module RuntimeEnvironment = LocalRuntimeEnvironment
  module EventCollectorChannel = LocalEventCollectorChannel.Make(Bus)
  module EventCollectorRuntimeBuilder = LocalEventCollectorRuntime_Builder.Make(
    Bus,
    EventCollectorChannel,
  )
  module QueryDbStorage = LocalQueryDbStorage.Make(Bus)
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

  module Make = (
    Spec: Reventless.OutboundTranslationSlice.Spec,
    Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
  ) => {
    module Inner = CoreMaker.Make(Spec, Translation)
    module Spec = Spec
    module Translation = Translation
    type component = Inner.component
    let queryDbName = Inner.queryDbName
    let make = Inner.make
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.OutboundTranslationSlice.operations> =
      ReventlessCore.Component.operations
  }
}
