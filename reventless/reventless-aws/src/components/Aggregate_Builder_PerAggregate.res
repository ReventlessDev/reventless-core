module CommandGeneratorResolvers = CommandGeneratorResolvers.AppSync
module CommandTopicChannel = CommandTopicChannel.SQS_FIFO
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module AggregateRuntimeBuilder = ReventlessCore.AggregateRuntime_Builder_Single.Make(
  RuntimeEnvironment,
  CommandTopicChannel,
  EventCollectorChannel,
)

module Make = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: ReventlessCore.Behavior.T with module Spec := Spec,
  EventMappings: ReventlessCore.EventMapper.Mappings with module Target := Spec,
) => ReventlessCore.Aggregate_Builder.Make(
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
