include Reventless.Plugin.Make(
  EventCollectorChannel.SQS,
  QueryEngine.DynamoDb,
  CommandTopicRemoteChannel.SQS,
  HeartbeatRunner.Lambda,
)
