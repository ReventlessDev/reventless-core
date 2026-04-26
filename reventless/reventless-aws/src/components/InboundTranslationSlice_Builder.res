// InboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Translation) for the
// new two-arg framework form. External signature stays on MergedSpec
// until Phase 5 migrates examples to native split form.

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
    Spec: Reventless.InboundTranslationSlice.MergedSpec,
  ): (
    ReventlessCore.InboundTranslationSlice.T
      with module Spec = Spec
  ) => {
    module LeanSpec = {
      let name = Spec.name
      let moduleUrl = Spec.moduleUrl
      type externalInput = Spec.externalInput
      let externalInputSchema = Spec.externalInputSchema
      type command = Spec.command
      let commandSchema = Spec.commandSchema
      let targetName = Spec.targetName
    }
    module TranslationImpl = {
      let translate = Spec.translate
      let moduleUrl = Spec.moduleUrl
    }
    module InnerMake = Inner.Make(LeanSpec, TranslationImpl)
    module Spec = Spec
    module Translation = TranslationImpl
    type component = InnerMake.component
    let queryDbName = InnerMake.queryDbName
    let make = InnerMake.make
  }
}
