module Make =
       (Spec: ReventlessSpec.AggregateSpec.T)
       : Reventless.CommandTopic.T =>
  Reventless.CommandTopic.Make(Spec, CommandTopicConnector_SQS_FIFO);
