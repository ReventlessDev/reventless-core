include Reventless.Plugin_Builder.Make(
  EventCollectorChannel.SQS,
  QueryEngine.DynamoDb,
  CommandTopicRemoteChannel.SQS,
  HeartbeatRunner.Lambda,
  RuntimeEnvironment_Lambda,
)
