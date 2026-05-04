module CommandTopicChannel = CommandTopicChannel.SQS_Sync
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = ExtensionPointRuntime_Builder_PerExtensionPoint

module Make = (
  Spec: ReventlessInfra.ExtensionPointMapping.Spec,
  Mappings: ReventlessInfra.ExtensionPoint.Mappings with module Spec := Spec,
): ReventlessInfra.ExtensionPoint.T =>
  ReventlessCore.ExtensionPoint_Builder.Make(
    Spec,
    Mappings,
    RuntimeEnvironment,
    CommandTopicChannel,
    EventTopicPublisher.SNS,
    ExtensionPointRuntimeBuilder,
  )
