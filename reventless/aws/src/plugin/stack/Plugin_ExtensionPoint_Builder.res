module CommandTopicChannel = CommandTopicChannel.SQS_Sync
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = PluginExtensionPointRuntime_Builder

module MakeWithConfig = (
  Config: {
    let updateApiSchema: option<Reventless.QueryEngine.operations => promise<unit>>
    let manageSubscriptions: option<
      (Reventless.Plugin.pluginDefinition, [#connect | #disconnect]) => promise<unit>,
    >
  },
): ReventlessCore.ExtensionPoint.T => ReventlessCore.PluginExtensionPoint_Builder.Make(
  {
    let runtimeOps = PluginRuntimeOperations.operations
    let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
    let updateApiSchema = Config.updateApiSchema
    let manageSubscriptions = Config.manageSubscriptions
  },
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  ExtensionPointRuntimeBuilder,
  ExtensionPoint_Builder.Defaults,
)

module Make: ReventlessCore.ExtensionPoint.T = MakeWithConfig({
  let updateApiSchema = None
  let manageSubscriptions = None
})
