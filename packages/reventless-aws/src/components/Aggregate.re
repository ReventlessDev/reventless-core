module Make =
       (
         Config: Config.T,
         Spec: ReventlessSpec.AggregateSpec.T,
         Behaviour: Reventless.Behaviour.T with module Spec := Spec,
         EventMappings:
           Reventless.EventMapper.Mappings with module Target := Spec,
       )
       : Reventless.Aggregate.T =>
  Reventless.Aggregate.Make(
    Config,
    Spec,
    Behaviour,
    EventMappings,
    CommandGeneratorResolvers.AppSync,
    CommandTopicConnector.SQS_FIFO,
    EventLogStorage.DynamoDbStream,
    EventTopicPublisher.DynamoDbStream,
    EventCollectorConnector_DynamoDbStream,
  );
