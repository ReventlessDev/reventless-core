// In-memory StateViewSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.StateViewSlice_Builder.
// Internal: splices a legacy MergedSpec into (Spec, Projection) for the
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

  module CoreMaker = ReventlessCore.StateViewSlice_Builder.Make(
    RuntimeEnvironment,
    QueryDbStorage,
    QueryDbResolvers,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    Api,
  )

  module Make = (Spec: Reventless.StateViewSlice.MergedSpec) => {
    module LeanSpec = {
      let name = Spec.name
      let moduleUrl = Spec.moduleUrl
      type state = Spec.state
      let stateSchema = Spec.stateSchema
      type consumedEvent = Spec.consumedEvent
      let consumedEventSchema = Spec.consumedEventSchema
      let config = Spec.config
      let subIdConfig = Spec.subIdConfig
    }
    module ProjectionImpl = {
      let project = Spec.project
      let moduleUrl = Spec.moduleUrl
    }
    module Inner = CoreMaker.Make(LeanSpec, ProjectionImpl)
    module Spec = Spec
    module Projection = ProjectionImpl
    type component = Inner.component
    let make = Inner.make
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.StateViewSlice.operations> =
      ReventlessCore.Component.operations
  }
}
