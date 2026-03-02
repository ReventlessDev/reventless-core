module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = ReventlessCore.ExtensionPointRuntime_Builder_PerExtensionPoint.Make(
  RuntimeEnvironment,
  CommandTopicChannel,
)

module Make: ReventlessCore.ExtensionPoint.T = ReventlessCore.PluginExtensionPoint_Builder.Make(
  {
    let runtimeOps = PluginRuntimeOperations.operations
    let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
    let updateApiSchema = None
  },
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  ExtensionPointRuntimeBuilder,
)
