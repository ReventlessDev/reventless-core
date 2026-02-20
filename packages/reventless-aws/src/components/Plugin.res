module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

include Reventless.Plugin_Builder.Make(
  {
    let runtimeOps = PluginRuntimeOperations.operations
    let resourceNaming = Util_ResourceNaming.operations
    let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
  },
  {
    type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
    type role = Pulumi.Output.t<PulumiAws.IAM.Role.t>
  },
  RuntimeEnvironment,
  EventCollectorChannel,
  QueryEngine.DynamoDb,
  CommandTopicRemoteChannel.SQS,
  HeartbeatRunner.CloudwatchEvents,
  Reventless.PluginRuntime_Builder_Micro.Make(RuntimeEnvironment, EventCollectorChannel),
  DcbEventLogStorage.DynamoDb,
  EventTopicPublisher.DynamoDbStream,
  CommandTopicChannel.SQS_FIFO,
)
