// In-memory OutboundTranslationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.OutboundTranslationSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Translation) for the
// new two-arg framework form. External signature stays on MergedSpec
// until Phase 5 migrates examples to native split form.

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
    module LeanSpec = {
      let name = Spec.name
      let moduleUrl = Spec.moduleUrl
      type consumedEvent = Spec.consumedEvent
      let consumedEventSchema = Spec.consumedEventSchema
      type outboundItem = Spec.outboundItem
      let outboundItemSchema = Spec.outboundItemSchema
      type inboundCommand = Spec.inboundCommand
      let inboundCommandSchema = Spec.inboundCommandSchema
      let maxRetries = Spec.maxRetries
      let heartbeatInterval = Spec.heartbeatInterval
      let targetName = Spec.targetName
    }
    module TranslationImpl = {
      let collect = Spec.collect
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
    let operations: component => Pulumi.Output.t<ReventlessCore.OutboundTranslationSlice.operations> =
      ReventlessCore.Component.operations
  }
}
