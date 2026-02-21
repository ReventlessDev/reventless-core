module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

include Reventless.Plugin_Builder.Make(
  {
    let runtimeOps = PluginRuntimeOperations.operations
    let resourceNaming = Util_ResourceNaming.operations
    let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
  },
  {
    type api = Types.AppSync.api
    type role = Types.AppSync.role
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
