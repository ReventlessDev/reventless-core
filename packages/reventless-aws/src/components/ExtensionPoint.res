module Make = (
  Spec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
): ReventlessSpec.ExtensionPoint.T => Reventless.ExtensionPoint.Make(
  Spec,
  Mappings,
  CommandTopicConnector.SQS,
  EventTopicPublisher.SNS,
)
