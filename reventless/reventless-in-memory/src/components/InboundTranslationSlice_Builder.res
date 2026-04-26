// In-memory InboundTranslationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.InboundTranslationSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Translation) for the
// new two-arg framework form. External signature stays on MergedSpec
// until Phase 5 migrates examples to native split form.

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
    module Inner = CoreMaker.Make(LeanSpec, TranslationImpl)
    module Spec = Spec
    module Translation = TranslationImpl
    type component = Inner.component
    let queryDbName = Inner.queryDbName
    let make = Inner.make
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.InboundTranslationSlice.operations> =
      ReventlessCore.Component.operations
  }
}
