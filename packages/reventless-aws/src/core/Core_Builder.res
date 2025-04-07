module EventCollectorChannel = EventCollectorChannel.SQS

module Make = (
  Config: Config.T with type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
) => Reventless.Core_Builder.Make(
  Config,
  EventCollectorChannel,
  QueryEngine.DynamoDb,
  ClonerRunner.Fargate,
  Reventless.PluginRuntime_Builder_Micro.Make(RuntimeEnvironment_Lambda, EventCollectorChannel),
)
