// In-memory ReadModel builder.

module Make = (Bus: LocalBus.T) => {
  module RuntimeEnvironment = LocalRuntimeEnvironment
  module EventCollectorChannel = LocalEventCollectorChannel.Make(Bus)
  module EventCollectorRuntimeBuilder = LocalEventCollectorRuntime_Builder.Make(
    Bus,
    EventCollectorChannel,
  )
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module QueryDbResolvers = QueryDbResolvers_GraphQL.Make(Bus)

  module Make = (
    Spec: Reventless.ReadModel.Spec,
    Mappings: Reventless.Projection.Mappings with module Target := Spec,
  ) =>
    ReventlessCore.ReadModel_Builder.Make(
      Spec,
      Mappings,
      RuntimeEnvironment,
      QueryDbStorage,
      QueryDbResolvers,
      EventCollectorChannel,
      EventCollectorRuntimeBuilder,
    )
}
