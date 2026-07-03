// In-memory ReadModel builder.

module Make = (Bus: LocalBus.T) => {
  module RuntimeEnvironment = LocalRuntimeEnvironment
  // MakeProjection (not Make): also registers the resolved handler for the
  // SQLite backend's startup projection catch-up (ProjectionCheckpoint).
  module EventCollectorChannel = LocalEventCollectorChannel.MakeProjection(Bus)
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

  // Resolver-free variant: registers the QueryDb store in the Bus and wires the
  // EventCollector subscription, but does NOT register GraphQL query resolvers.
  // Used for admin read models whose query resolvers are hand-registered onto the
  // platform server by Platform.res (the auto resolvers would otherwise register
  // admin-typed fields onto the domain server and break its schema). Mirrors the
  // AWS NoResolver builder + core QueryDb_Adapter.NoResolvers.
  module NoResolvers = ReventlessCore.QueryDb_Adapter.NoResolvers(QueryDbStorage)
  module MakeNoResolver = (
    Spec: Reventless.ReadModel.Spec,
    Mappings: Reventless.Projection.Mappings with module Target := Spec,
  ) =>
    ReventlessCore.ReadModel_Builder.Make(
      Spec,
      Mappings,
      RuntimeEnvironment,
      QueryDbStorage,
      NoResolvers,
      EventCollectorChannel,
      EventCollectorRuntimeBuilder,
    )
}
