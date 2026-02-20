module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorChannel = EventCollectorChannel.SQS

include Reventless.Core_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  QueryEngine.DynamoDb,
  ClonerRunner.Fargate,
  Reventless.PluginRuntime_Builder_Micro.Make(RuntimeEnvironment_Lambda, EventCollectorChannel),
)
