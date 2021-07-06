module Make =
       (Spec: Reventless.ExtensionPoint.Spec)
       : Reventless.ExtensionPoint.T =>
  Reventless.ExtensionPoint.Make(
    Spec,
    CommandTopicConnector.SQS,
    EventTopicPublisher.SNS,
  );
