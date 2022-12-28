module Make =
       (
         Config: Config.T,
         Spec: ReventlessSpec.ReadModelSpec.T,
         Mappings:
           ReventlessSpec.Projection.Mappings with module Target := Spec,
       )
       : Reventless.ReadModel.T =>
  Reventless.ReadModel.Make(
    Config,
    Spec,
    Mappings,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
    EventCollectorConnector.DynamoDbStream,
  );
