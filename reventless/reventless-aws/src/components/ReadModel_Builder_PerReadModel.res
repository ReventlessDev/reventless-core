module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)

module Make = (
  Spec: Reventless.ReadModel.Spec,
  Mappings: Reventless.Projection.Mappings with module Target := Spec,
) => ReventlessCore.ReadModel_Builder.Make(
  Spec,
  Mappings,
  RuntimeEnvironment,
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  EventCollectorChannel,
  EventCollectorRuntimeBuilder,
)
