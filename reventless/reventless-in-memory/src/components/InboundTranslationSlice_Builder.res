// In-memory InboundTranslationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.

module Make = (Bus: InMemory_Bus.T) => {
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module QueryDbResolvers = QueryDbResolvers_GraphQL.Make(Bus)

  // InMemory api/apiRole are both unit
  module Api = {
    let api = () => ()
    let apiRole = () => ()
  }

  module CoreMaker = ReventlessCore.InboundTranslationSlice_Builder.Make(
    QueryDbStorage,
    QueryDbResolvers,
    Api,
  )

  module Make = (Spec: Reventless.InboundTranslationSlice.MergedSpec) => {
    include CoreMaker.Make(Spec)
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.InboundTranslationSlice.operations> =
      ReventlessCore.Component.operations
  }
}
