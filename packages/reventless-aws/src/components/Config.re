module type T =
  Reventless.Config.T with
    type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t) and
    type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);
