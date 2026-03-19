module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = PluginExtensionPointRuntime_Builder_Bundled

module MakeWithConfig = (
  Config: {
    let updateApiSchema: option<Reventless.QueryEngine.operations => promise<unit>>
  },
): ReventlessCore.ExtensionPoint.T => ReventlessCore.PluginExtensionPoint_Builder.Make(
  {
    let runtimeOps = PluginRuntimeOperations.operations
    let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
    let updateApiSchema = Config.updateApiSchema
  },
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  ExtensionPointRuntimeBuilder,
)

module Make: ReventlessCore.ExtensionPoint.T = MakeWithConfig({
  let updateApiSchema = None
})
