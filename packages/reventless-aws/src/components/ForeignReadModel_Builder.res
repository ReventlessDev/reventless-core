module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = Reventless.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)

module Make = (
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
) => Reventless.ReadModel_Builder.Make(
  Spec,
  Mappings,
  RuntimeEnvironment,
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  EventCollectorChannel,
  EventCollectorRuntimeBuilder,
)
