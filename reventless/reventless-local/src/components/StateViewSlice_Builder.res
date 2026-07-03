// In-memory StateViewSlice builder.
// Wires in-memory adapters and delegates to the core ReventlessCore.StateViewSlice_Builder.

module Make = (Bus: LocalBus.T) => {
  module RuntimeEnvironment = LocalRuntimeEnvironment
  // MakeProjection (not Make): also registers the resolved handler for the
  // SQLite backend's startup projection catch-up (ProjectionCheckpoint) —
  // StateViewSlices are pure projections fed by DCB events.
  module EventCollectorChannel = LocalEventCollectorChannel.MakeProjection(Bus)
  module EventCollectorRuntimeBuilder = LocalEventCollectorRuntime_Builder.Make(
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

  module Make = (
    Spec: Reventless.StateViewSlice.Spec,
    Projection: Reventless.StateViewSlice.Projection with module Spec := Spec,
  ) => {
    module Inner = CoreMaker.Make(Spec, Projection)
    module Spec = Spec
    module Projection = Projection
    type component = Inner.component
    let make = Inner.make
    // Re-expose operations for test resolution
    let operations: component => Pulumi.Output.t<ReventlessCore.StateViewSlice.operations> =
      ReventlessCore.Component.operations
  }
}
