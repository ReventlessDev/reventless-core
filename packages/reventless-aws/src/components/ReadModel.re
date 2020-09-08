module Make =
       (
         Config:
           Reventless.Config.T with
             type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t) and
             type role = Pulumi.Output.t(PulumiAws.IAM.Role.t),
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
