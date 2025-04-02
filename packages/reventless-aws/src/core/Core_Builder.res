module Make = (
  Config: Config.T with type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
) => Reventless.Core_Builder.Make(
  Config,
  EventCollectorChannel.SQS,
  QueryEngine.DynamoDb,
  ClonerRunner.Fargate,
  Reventless.Runtime_Builder_Micro.Make(RuntimeEnvironment_Lambda),
)
