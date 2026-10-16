// In-memory InboundTranslationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.

module Make = (Bus: LocalBus.T) => {
  module QueryDbStorage = LocalQueryDbStorage.Make(Bus)
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

  module Make = (
    Spec: Reventless.InboundTranslationSlice.Spec,
    Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
  ) => {
    module Inner = CoreMaker.Make(Spec, Translation)
    module Spec = Spec
    module Translation = Translation
    type component = Inner.component
    let queryDbName = Inner.queryDbName
    let make = (~publishJsons, ~runtime=?, ~opts=?) => {
      let component = Inner.make(~publishJsons, ~runtime?, ~opts?)
      Spec.endpoint->Option.forEach(endpoint =>
        LocalWebhookRegistry.register(
          ~route=ReventlessCore.InboundTranslationSlice_Webhook.routeOf(~slice=Spec.name, endpoint),
          ~operations=component->ReventlessCore.Component.operations,
        )
      )
      component
    }
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<
      ReventlessCore.InboundTranslationSlice.operations,
    > = ReventlessCore.Component.operations
  }
}
