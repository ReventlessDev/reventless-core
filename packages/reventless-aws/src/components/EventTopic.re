module Make = (Spec: ReventlessSpec.AggregateSpec.T) : Reventless.EventTopic.T =>
  Reventless.EventTopic.Make(Spec, EventTopicPublisher.SNS);
