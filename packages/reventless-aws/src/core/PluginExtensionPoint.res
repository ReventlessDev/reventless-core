module Make: ReventlessSpec.ExtensionPoint.T = Reventless.PluginExtensionPoint.Make(
  CommandTopicConnector.SQS,
  EventTopicPublisher.SNS,
)
