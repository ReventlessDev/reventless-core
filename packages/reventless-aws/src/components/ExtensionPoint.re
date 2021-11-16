module Make =
       (
         Spec: Reventless.ExtensionPoint.Spec,
         Mappings: Reventless.ExtensionPoint.Mappings with module Spec := Spec,
       )
       : Reventless.ExtensionPoint.T =>
  Reventless.ExtensionPoint.Make(
    Spec,
    Mappings,
    CommandTopicConnector.SQS,
    EventTopicPublisher.SNS,
  );
