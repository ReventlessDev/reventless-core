include Reventless.Plugin.Make(
  EventCollectorConnector.SQS,
  QueryEngine.DynamoDb,
  CommandTopicRemoteChannel.SQS,
  HeartbeatRunner.Lambda,
)
