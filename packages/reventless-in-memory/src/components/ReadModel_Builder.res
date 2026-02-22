// In-memory ReadModel builder.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_InMemory.Make(
    Bus,
    EventCollectorChannel,
  )

  module Make = (
    Spec: ReventlessSpec.ReadModel.Spec,
    Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
  ) =>
    Reventless.ReadModel_Builder.Make(
      Spec,
      Mappings,
      RuntimeEnvironment,
      QueryDbStorage_InMemory,
      Reventless.QueryDb_Adapter.NoResolvers(QueryDbStorage_InMemory),
      EventCollectorChannel,
      EventCollectorRuntimeBuilder,
    )
}
