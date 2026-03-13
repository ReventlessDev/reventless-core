module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorChannel = EventCollectorChannel.SQS

include ReventlessCore.Core_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  QueryEngine.DynamoDb,
  ClonerRunner.Fargate,
  ReventlessCore.PluginRuntime_Builder_Micro.Make(RuntimeEnvironment_Lambda, EventCollectorChannel),
  DcbEventLogStorage.DynamoDb,
  EventTopicPublisher.DynamoDbStream,
  CommandTopicChannel.SQS_FIFO,
)
