module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Reventless.Behaviour.T with module Spec := Spec,
  EventMappings: Reventless.EventMapper.Mappings with module Target := Spec,
): Reventless.Aggregate.T => Reventless.Aggregate_Builder.Make(
  Config,
  Spec,
  Behaviour,
  EventMappings,
  CommandGeneratorResolvers.AppSync_Lambda,
  CommandTopicChannel.SQS_FIFO,
  EventLogStorage.DynamoDbStream,
  EventTopicPublisher.DynamoDbStream,
  EventCollectorChannel_DynamoDbStream,
  RuntimeEnvironment_Lambda,
)
