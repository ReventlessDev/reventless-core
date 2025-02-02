module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
): (Reventless.ReadModel.T with module Spec = Spec) => Reventless.ReadModel.Make(
  Config,
  Spec,
  Mappings,
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  EventCollectorConnector.SQS,
)
