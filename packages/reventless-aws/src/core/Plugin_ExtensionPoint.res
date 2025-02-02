module Make: Reventless.ExtensionPoint.T = Reventless.PluginExtensionPoint.Make(
  CommandTopicConnector.SQS,
  EventTopicPublisher.SNS,
)
