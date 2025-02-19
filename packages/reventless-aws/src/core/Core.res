module Make = (
  Config: Config.T with type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
) => Reventless.Core.Make(
  Config,
  EventCollectorChannel.SQS,
  QueryEngine.DynamoDb,
  ClonerRunner.Fargate,
)
