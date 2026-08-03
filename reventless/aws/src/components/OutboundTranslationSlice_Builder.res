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

    let make = (~dcbEventLog, ~allEventTopics=Dict.make(), ~publishJsons, ~runtime=?, ~opts=?): component => {
      let ots = InnerMake.make(~dcbEventLog, ~allEventTopics, ~publishJsons, ~runtime?, ~opts?)

      let queryDbOutputs = (ots->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      // Which streams this slice's Lambda must actually listen on. The core
      // `make` above has already validated every declared name and thrown on a
      // typo, so this only has to select — a name absent from `allEventTopics`
      // is necessarily the plugin's own DCB log, the one source that dict does
      // not carry.
      let declaredSources = Spec.sourceNames
      let sourceTopics =
        allEventTopics->ReventlessCore.EventTopic.filter(
          declaredSources->Belt.Set.String.fromArray,
        )
      let consumesDcbLog =
        declaredSources->Array.length == 0 ||
          declaredSources->Array.some(name => !(allEventTopics->Dict.has(name)))

      AutomationSliceRuntime_Builder_Single.registerAutomationSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~bodyModulePath=Util_Bundle.getModuleSpecifier(Translation.moduleUrl),
        ~callbackType="outbound",
        ~queryDbTableName,
        ~queryDbResources=queryDbOutputs.resources,
        ~sourceTopics,
        ~consumesDcbLog,
      )

      ots
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
