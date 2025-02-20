module Make: Reventless.ExtensionPoint.T = Reventless.PluginExtensionPoint_Builder.Make(
  CommandTopicChannel.SQS,
  EventTopicPublisher.SNS,
  RuntimeEnvironment_Lambda_SQS,
)
