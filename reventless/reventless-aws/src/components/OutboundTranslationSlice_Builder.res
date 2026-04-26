// OutboundTranslationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.OutboundTranslationSlice_Builder.

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
    Spec: Reventless.OutboundTranslationSlice.Spec,
    Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec,
  ): (ReventlessCore.OutboundTranslationSlice.T with module Spec = Spec) => {
    module InnerMake = Inner.Make(Spec, Translation)

    module Spec = Spec
    module Translation = Translation
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
