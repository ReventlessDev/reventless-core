module Make = (ApiValues: {
  let api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
  let apiRole: Pulumi.Output.t<PulumiAws.IAM.Role.t>
}) => Reventless.Counter_Builder.Make(
  QueryDbStorage_DynamoDbStream,
  ApiValues,
  CounterHandler_DynamoDbStream,
)
