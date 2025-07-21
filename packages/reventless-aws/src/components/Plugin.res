module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

include Reventless.Plugin_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  QueryEngine.DynamoDb,
  CommandTopicRemoteChannel.SQS,
  HeartbeatRunner.CloudwatchEvents,
  Reventless.PluginRuntime_Builder_Micro.Make(RuntimeEnvironment, EventCollectorChannel),
)
