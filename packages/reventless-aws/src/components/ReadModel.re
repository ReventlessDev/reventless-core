module Make =
       (Config: Config.T, Spec: ReventlessSpec.ReadModelSpec.T)
       : Reventless.ReadModel.T =>
  Reventless.ReadModel.Make(
    Config,
    Spec,
    View,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
  );
