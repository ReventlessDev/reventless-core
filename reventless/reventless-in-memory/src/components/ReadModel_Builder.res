// In-memory ReadModel builder.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_InMemory.Make(
    Bus,
    EventCollectorChannel,
  )
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module QueryDbResolvers = QueryDbResolvers_GraphQL.Make(Bus)

  module Make = (
    Spec: ReventlessSpec.ReadModel.Spec,
    Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
  ) =>
    Reventless.ReadModel_Builder.Make(
      Spec,
      Mappings,
      RuntimeEnvironment,
      QueryDbStorage,
      QueryDbResolvers,
      EventCollectorChannel,
      EventCollectorRuntimeBuilder,
    )
}
