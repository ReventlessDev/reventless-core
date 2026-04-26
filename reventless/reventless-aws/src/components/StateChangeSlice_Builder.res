// AWS StateChangeSlice builder — splits the legacy MergedSpec into
// (Spec, Behavior) for the new two-arg framework form. External signature
// stays on MergedSpec until Phase 5 migrates examples to native split form.

module Make = (Spec: Reventless.StateChangeSlice.MergedSpec): (
  ReventlessCore.StateChangeSlice.T
    with module Spec = Spec
) => {
  PluginRuntime_Builder.registerStateChangeSliceSpec(
    Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
  )
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
  let make = Inner.make
}
