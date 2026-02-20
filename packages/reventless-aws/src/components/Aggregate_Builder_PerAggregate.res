module CommandGeneratorResolvers = CommandGeneratorResolvers.AppSync
module CommandTopicChannel = CommandTopicChannel.SQS_FIFO
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module AggregateRuntimeBuilder = Reventless.AggregateRuntime_Builder_Single.Make(
  RuntimeEnvironment,
  CommandTopicChannel,
  EventCollectorChannel,
)

module Make = (
  Spec: ReventlessSpec.Aggregate.Spec,
  Behavior: Reventless.Behavior.T with module Spec := Spec,
  EventMappings: Reventless.EventMapper.Mappings with module Target := Spec,
) => Reventless.Aggregate_Builder.Make(
  Spec,
  Behavior,
  EventMappings,
  RuntimeEnvironment,
  CommandGeneratorResolvers,
  CommandTopicChannel,
  EventLogStorage.DynamoDbStream,
  EventTopicPublisher.DynamoDbStream,
  EventCollectorChannel,
  AggregateRuntimeBuilder,
)
