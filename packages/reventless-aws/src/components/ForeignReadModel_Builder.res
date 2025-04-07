module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
): (Reventless.ReadModel.T with module Spec = Spec) => Reventless.ReadModel_Builder.Make(
  Config,
  Spec,
  Mappings,
  RuntimeEnvironment,
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  EventCollectorChannel,
  Reventless.ReadModelRuntime_Builder_Micro.Make(RuntimeEnvironment, EventCollectorChannel),
)
