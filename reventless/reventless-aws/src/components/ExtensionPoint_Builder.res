module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = ReventlessCore.ExtensionPointRuntime_Builder_PerExtensionPoint.Make(
  RuntimeEnvironment,
  CommandTopicChannel,
)

module Make = (
  Spec: Reventless.ExtensionPointMapping.Spec,
  Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
): Reventless.ExtensionPoint.T => ReventlessCore.ExtensionPoint_Builder.Make(
  Spec,
  Mappings,
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  ExtensionPointRuntimeBuilder,
)
