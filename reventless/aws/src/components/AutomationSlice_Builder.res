// AutomationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.AutomationSlice_Builder.

module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = AutomationSliceRuntime_Builder_Single

// The core builder's operations never run on AWS: the automation Lambda drives the
// callback itself (AutomationSliceEntryPoint_Ops).
module DeployTimeSchedules = {
  let platformFor = (~slice): ReventlessInfra.AutomationSlice.platformSchedules => {
    let refuse = () =>
      JsError.throwWithMessage(
        `AutomationSlice(${slice}): schedules are set by its Lambda, not at deploy`,
      )
    {
      put: async (~key as _, _) => refuse(),
      removeName: async _ => refuse(),
      names: async () => refuse(),
      nameOf: key => key,
    }
  }
}

module Make = (
  Api: {
    let api: unit => Types.AppSync.api
    let apiRole: unit => Types.AppSync.role
  },
) => {
  module Inner = ReventlessCore.AutomationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
    DeployTimeSchedules,
    OutboundTranslationSlice_Builder.DeployTimeCapabilities,
  )

  module Make = (
    Spec: Reventless.AutomationSlice.Spec,
    Automation: Reventless.AutomationSlice.Automation with module Spec := Spec,
  ): (ReventlessCore.AutomationSlice.T with module Spec = Spec) => {
    module InnerMake = Inner.Make(Spec, Automation)

    module Spec = Spec
    module Automation = Automation
    type component = InnerMake.component
    let queryDbName = InnerMake.queryDbName
    let schedulesDbName = InnerMake.schedulesDbName
    let sourceNames = InnerMake.sourceNames

    let make = (~allEventTopics, ~publishJsons, ~context, ~runtime=?, ~opts=?): component => {
      let as_ = InnerMake.make(~allEventTopics, ~publishJsons, ~context, ~runtime?, ~opts?)

      let queryDbOutputs = (as_->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      // An automation names its sources through its Mappings rather than a flat
      // list, but the runtime question is the same one the outbound builder
      // answers: which streams must this Lambda listen on. Unlike outbound, an
      // automation's DCB log is already a key in `allEventTopics`, so the filter
      // picks it up and nothing extra has to be assumed.
      let sourceTopics =
        allEventTopics->ReventlessCore.EventTopic.filter(sourceNames->Belt.Set.String.fromArray)
      let consumesDcbLog =
        sourceNames->Array.length == 0 ||
          sourceNames->Array.some(name => !(allEventTopics->Dict.has(name)))

      EventCollectorRuntimeBuilder.registerAutomationSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~bodyModulePath=Util_Bundle.getModuleSpecifier(Automation.moduleUrl),
        ~callbackType="automation",
        ~queryDbTableName,
        ~queryDbResources=queryDbOutputs.resources,
        ~context,
        ~sourceTopics,
        ~consumesDcbLog,
        ~schedule=?Spec.schedule,
        ~schedulesResources=(as_->ReventlessCore.Component.outputs).schedulesDb->Option.mapOr(
          [],
          db => db.resources,
        ),
      )

      as_
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
