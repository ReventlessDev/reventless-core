module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module Make: Reventless.ExtensionPoint.T = Reventless.PluginExtensionPoint_Builder.Make(
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  Reventless.ExtensionPointRuntime_Builder_Micro.Make(RuntimeEnvironment, CommandTopicChannel),
)
