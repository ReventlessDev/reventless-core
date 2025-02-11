include Reventless.Plugin.Make(
  EventCollectorConnector.SQS,
  QueryEngine.DynamoDb,
  CommandTopicRemoteConnector.SQS,
  HeartbeatRunner.Lambda,
)
