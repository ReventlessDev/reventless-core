// AutomationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.AutomationSlice_Builder.

module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = AutomationSliceRuntime_Builder_Single

module Make = (Api: {
  let api: unit => Types.AppSync.api
  let apiRole: unit => Types.AppSync.role
}) => {
  module Inner = ReventlessCore.AutomationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
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
    let sourceNames = InnerMake.sourceNames

    let make = (~allEventTopics, ~publishJsons, ~context, ~runtime=?, ~opts=?): component => {
      let as_ = InnerMake.make(~allEventTopics, ~publishJsons, ~context, ~runtime?, ~opts?)

      let queryDbOutputs = (as_->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      EventCollectorRuntimeBuilder.registerAutomationSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~bodyModulePath=Util_Bundle.getModuleSpecifier(Automation.moduleUrl),
        ~callbackType="automation",
        ~queryDbTableName,
        ~context,
      )

      as_
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
