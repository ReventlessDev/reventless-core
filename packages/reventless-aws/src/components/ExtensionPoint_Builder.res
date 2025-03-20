module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
): Reventless.ExtensionPoint.T => Reventless.ExtensionPoint_Builder.Make(
  Spec,
  Mappings,
  RuntimeEnvironment_Lambda,
  CommandTopicChannel.SQS,
  EventTopicPublisher.SNS,
)
