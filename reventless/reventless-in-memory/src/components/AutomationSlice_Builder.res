// In-memory AutomationSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.AutomationSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Automation) for the
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

  module CoreMaker = ReventlessCore.AutomationSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (Spec: Reventless.AutomationSlice.MergedSpec) => {
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
    module Inner = CoreMaker.Make(LeanSpec, AutomationImpl)
    module Spec = Spec
    module Automation = AutomationImpl
    type component = Inner.component
    let queryDbName = Inner.queryDbName
    let make = Inner.make
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.AutomationSlice.operations> =
      ReventlessCore.Component.operations
  }
}
