// OutboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.OutboundTranslationSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Translation) for the
// new two-arg framework form. External signature stays on MergedSpec
// until Phase 5 migrates examples to native split form.

module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module EventCollectorRuntimeBuilder = {
  module Inner = AutomationSliceRuntime_Builder_Single
  type context = Inner.context
  type runtimeParts = Inner.runtimeParts
  module EventCollectorChannel = Inner.EventCollectorChannel

  let forEventCollector = Inner.forEventCollector
  let finish = Inner.finish
}

module Make = (Api: {
  let api: unit => Types.AppSync.api
  let apiRole: unit => Types.AppSync.role
}) => {
  module Inner = ReventlessCore.OutboundTranslationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (
    Spec: Reventless.OutboundTranslationSlice.MergedSpec,
  ): (
    ReventlessCore.OutboundTranslationSlice.T
      with module Spec = Spec
  ) => {
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
    module InnerMake = Inner.Make(LeanSpec, TranslationImpl)

    module Spec = Spec
    module Translation = TranslationImpl
    type component = InnerMake.component
    let queryDbName = InnerMake.queryDbName

    let make = (~dcbEventLog, ~publishJsons, ~opts=?): component => {
      let ots = InnerMake.make(~dcbEventLog, ~publishJsons, ~opts?)

      let queryDbOutputs = (ots->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      AutomationSliceRuntime_Builder_Single.registerAutomationSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~callbackType="outbound",
        ~queryDbTableName,
      )

      ots
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
