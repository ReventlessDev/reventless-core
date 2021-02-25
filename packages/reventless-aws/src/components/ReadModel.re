module Make =
       (
         Config: Config.T,
         Spec: Reventless.Aggregate.Spec,
         View: Reventless.View.T with module Spec := Spec,
       )
       : Reventless.ReadModel.T =>
  Reventless.ReadModel.Make(
    Config,
    Spec,
    View,
    QueryDbStorage.DynamoDb,
    QueryDbResolvers.AppSync,
  );
