module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = Reventless.ExtensionPointRuntime_Builder_PerExtensionPoint.Make(
  RuntimeEnvironment,
  CommandTopicChannel,
)

module Make: Reventless.ExtensionPoint.T = Reventless.PluginExtensionPoint_Builder.Make(
  {
    let runtimeOps = PluginRuntimeOperations.operations
    let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
  },
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  ExtensionPointRuntimeBuilder,
)
