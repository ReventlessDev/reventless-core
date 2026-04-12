module CommandGeneratorResolvers = CommandGeneratorResolvers.AppSync
module CommandTopicChannel = CommandTopicChannel.SQS_Async
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module AggregateRuntimeBuilder = AggregateRuntime_Builder_Single_Async

module Make = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: Reventless.Behavior.T with module Spec := Spec,
  EventMappings: ReventlessInfra.EventMapper.Mappings with module Target := Spec,
): (
  ReventlessInfra.Aggregate.T
    with type api = CommandGeneratorResolvers.api
    and type component = ReventlessCore.Aggregate.component
) => {
  module Inner = ReventlessCore.Aggregate_Builder.Make(
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
    ReventlessCore.Plugin_Helpers.NoopHooksConfig,
  )

  module Spec = Spec
  module AggregateRuntimeBuilder = AggregateRuntimeBuilder

  type api = Inner.api
  type component = Inner.component

  let make = (~api, ~opts=?): component => {
    let aggregate = Inner.make(~api, ~opts?)

    // Extract the event log table name from the aggregate's outputs.
    // EventLog.outputs.resources[0] is the DynamoDB table resource.
    let eventLogOutputs = (aggregate->Inner.outputs).eventLog
    let tableResource = eventLogOutputs.resources->Array.getUnsafe(0)
    let eventLogTableName = tableResource.name

    AggregateRuntimeBuilder.registerAggregate(
      ~aggregateName=Spec.name,
      ~specModulePath=Util_Bundle.getModuleSpecifier(Spec.moduleUrl),
      ~behaviorModulePath=Util_Bundle.getModuleSpecifier(Behavior.moduleUrl),
      ~eventLogTableName,
    )

    aggregate
  }

  let outputs = Inner.outputs
  let operations = Inner.operations
  let finish = () => AggregateRuntimeBuilder.finish()
}
