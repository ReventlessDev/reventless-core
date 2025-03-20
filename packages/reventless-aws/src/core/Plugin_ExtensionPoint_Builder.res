module Make: Reventless.ExtensionPoint.T = Reventless.PluginExtensionPoint_Builder.Make(
  RuntimeEnvironment_Lambda,
  CommandTopicChannel.SQS,
  EventTopicPublisher.SNS,
)
