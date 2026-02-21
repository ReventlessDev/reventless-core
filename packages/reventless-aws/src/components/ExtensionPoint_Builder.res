module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module ExtensionPointRuntimeBuilder = Reventless.ExtensionPointRuntime_Builder_PerExtensionPoint.Make(
  RuntimeEnvironment,
  CommandTopicChannel,
)

module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: ReventlessSpec.ExtensionPoint.Mappings with module Spec := Spec,
): ReventlessSpec.ExtensionPoint.T => Reventless.ExtensionPoint_Builder.Make(
  Spec,
  Mappings,
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  ExtensionPointRuntimeBuilder,
)
