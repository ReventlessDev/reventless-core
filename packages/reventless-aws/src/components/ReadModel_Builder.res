module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
): (Reventless.ReadModel.T with module Spec = Spec) => Reventless.ReadModel_Builder.Make(
  Config,
  Spec,
  Mappings,
  Reventless.Runtime_Builder_Micro.Make(RuntimeEnvironment_Lambda),
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  EventCollectorChannel.DynamoDbStream,
)
