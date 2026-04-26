module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module Make = (HooksConfig: ReventlessCore.Plugin_Helpers.HooksConfig) => {
  include ReventlessCore.Plugin_Builder.Make(
    {
      let runtimeOps = PluginRuntimeOperations.operations
      let resourceNaming = Util_ResourceNaming.operations
      let environment = PulumiAws.Lambda.environment->Option.getOr("unknown")
      let platformName = Pulumi.Pulumi.getProjectName()
      let hooks = HooksConfig.hooks
    },
    {
      type api = Types.AppSync.api
      type role = Types.AppSync.role
    },
    AppSync_Adapter,
    RuntimeEnvironment,
    EventCollectorChannel,
    QueryEngine.DynamoDb,
    CommandTopicRemoteChannel.SQS,
    HeartbeatRunner.CloudwatchEvents,
    PluginRuntime_Builder.Make(EventCollectorChannel),
    DcbEventLogStorage.DynamoDb,
    EventTopicPublisher.DynamoDbStream,
    CommandTopicChannel.SQS_Sync,
    CommandTopicChannel.SQS_Async,
  )
}
