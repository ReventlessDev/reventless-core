module Make = (Spec: Reventless.DcbEventLog.Spec): (
  ReventlessCore.DcbEventLog.T with module Spec = Spec
) => {
  PluginRuntime_Builder.registerDcbEventLogModulePath(
    Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
  )
  include ReventlessCore.DcbEventLog_Builder.Make(
    Spec,
    DcbEventLogStorage.DynamoDb,
    EventTopicPublisher.DynamoDbStream,
  )
}
