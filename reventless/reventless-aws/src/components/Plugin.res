module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

include ReventlessCore.Plugin_Builder.Make(
  {
    let runtimeOps = PluginRuntimeOperations.operations
    let resourceNaming = Util_ResourceNaming.operations
    let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
  },
  {
    type api = Types.AppSync.api
    type role = Types.AppSync.role
  },
  AppSync_Adapter,
  RuntimeEnvironment,
  EventCollectorChannel,
  QueryEngine.DynamoDb,
  CommandTopicRemoteChannel.SQS,
  HeartbeatRunner.CloudwatchEvents,
  PluginRuntime_Builder.Make(EventCollectorChannel),
  DcbEventLogStorage.DynamoDb,
  EventTopicPublisher.DynamoDbStream,
  CommandTopicChannel.SQS_FIFO,
)
