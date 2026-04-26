// AutomationSlice_Builder (AWS)
// Wires AWS adapters and delegates to the core ReventlessCore.AutomationSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Automation) for the
// new two-arg framework form. External signature stays on MergedSpec
// until Phase 5 migrates examples to native split form.

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
    Spec: Reventless.AutomationSlice.MergedSpec,
  ): (
    ReventlessCore.AutomationSlice.T
      with module Spec = Spec
  ) => {
    module LeanSpec = {
      let name = Spec.name
      let moduleUrl = Spec.moduleUrl
      type consumedEvent = Spec.consumedEvent
      let consumedEventSchema = Spec.consumedEventSchema
      type todoItem = Spec.todoItem
      let todoItemSchema = Spec.todoItemSchema
      type command = Spec.command
      let commandSchema = Spec.commandSchema
      let maxRetries = Spec.maxRetries
      let heartbeatInterval = Spec.heartbeatInterval
      let targetName = Spec.targetName
    }
    module AutomationImpl = {
      let collect = Spec.collect
      let resolve = Spec.resolve
      let process = Spec.process
      let moduleUrl = Spec.moduleUrl
    }
    module InnerMake = Inner.Make(LeanSpec, AutomationImpl)

    module Spec = Spec
    module Automation = AutomationImpl
    type component = InnerMake.component
    let queryDbName = InnerMake.queryDbName

    let make = (~dcbEventLog, ~publishJsons, ~opts=?): component => {
      let as_ = InnerMake.make(~dcbEventLog, ~publishJsons, ~opts?)

      let queryDbOutputs = (as_->ReventlessCore.Component.outputs).queryDb
      let tableResource = queryDbOutputs.resources->Array.getUnsafe(0)
      let queryDbTableName = tableResource.name

      EventCollectorRuntimeBuilder.registerAutomationSlice(
        ~name=Spec.name,
        ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
        ~callbackType="automation",
        ~queryDbTableName,
      )

      as_
    }
  }

  let finish = () => EventCollectorRuntimeBuilder.finish()
}
