include Reventless.Plugin_Builder.Make(
  RuntimeEnvironment_Lambda,
  EventCollectorChannel.SQS,
  QueryEngine.DynamoDb,
  CommandTopicRemoteChannel.SQS,
  HeartbeatRunner.CloudwatchEvents,
)
