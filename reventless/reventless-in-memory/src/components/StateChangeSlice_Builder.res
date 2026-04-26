// StateChangeSlice builder — no platform-specific adapters needed.
// Internal: splices a legacy MergedSpec into (Spec, Behavior) for the
// new two-arg framework form. External signature stays on MergedSpec
// until Phase 5 migrates examples to native split form.

module Make = (Spec: Reventless.StateChangeSlice.MergedSpec) => {
  module LeanSpec = {
    let name = Spec.name
    let moduleUrl = Spec.moduleUrl
    module Id = Spec.Id
    type consumedEvent = Spec.consumedEvent
    let consumedEventSchema = Spec.consumedEventSchema
    type command = Spec.command
    let commandSchema = Spec.commandSchema
    type error = Spec.error
    let errorSchema = Spec.errorSchema
    type event = Spec.event
    let eventSchema = Spec.eventSchema
  }
  module BehaviorImpl = {
    type state = Spec.state
    let initialState = Spec.initialState
    let evolve = Spec.evolve
    let decide = Spec.decide
    let moduleUrl = Spec.moduleUrl
  }
  module Inner = ReventlessCore.StateChangeSlice_Builder.Make(LeanSpec, BehaviorImpl)
  module Spec = Spec
  module Behavior = BehaviorImpl
  let isAsync = Inner.isAsync
  type component = Inner.component
  let make: (
    ~dcbEventLog: ReventlessInfra.DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<ReventlessInfra.CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = Inner.make
}
