// InboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.

module Make = (Api: {
  let api: unit => Types.AppSync.api
  let apiRole: unit => Types.AppSync.role
}) => {
  module Inner = ReventlessCore.InboundTranslationSlice_Builder.Make(
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    Api,
  )

  module Make = (
    Spec: Reventless.InboundTranslationSlice.Spec,
    Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
  ): (ReventlessCore.InboundTranslationSlice.T with module Spec = Spec) => {
    module InnerMake = Inner.Make(Spec, Translation)
    module Spec = Spec
    module Translation = Translation
    type component = InnerMake.component
    let queryDbName = InnerMake.queryDbName
    let make = InnerMake.make
  }
}
