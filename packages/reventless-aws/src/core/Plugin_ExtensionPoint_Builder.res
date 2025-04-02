module Make: Reventless.ExtensionPoint.T = Reventless.PluginExtensionPoint_Builder.Make(
  Reventless.Runtime_Builder_Micro.Make(RuntimeEnvironment_Lambda),
  CommandTopicChannel.SQS,
  EventTopicPublisher.SNS,
)
