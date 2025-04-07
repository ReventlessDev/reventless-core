module CommandTopicChannel = CommandTopicChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
): Reventless.ExtensionPoint.T => Reventless.ExtensionPoint_Builder.Make(
  Spec,
  Mappings,
  RuntimeEnvironment,
  CommandTopicChannel,
  EventTopicPublisher.SNS,
  Reventless.ExtensionPointRuntime_Builder_Micro.Make(RuntimeEnvironment, CommandTopicChannel),
)
