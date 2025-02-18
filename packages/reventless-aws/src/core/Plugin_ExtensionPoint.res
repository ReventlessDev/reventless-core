module Make: Reventless.ExtensionPoint.T = Reventless.PluginExtensionPoint.Make(
  CommandTopicChannel.SQS,
  EventTopicPublisher.SNS,
  RuntimeEnvironment_Lambda_SQS,
)
