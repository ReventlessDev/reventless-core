module CommandGeneratorResolvers = CommandGeneratorResolvers.AppSync
module CommandTopicChannel = CommandTopicChannel.SQS_Sync
module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda

module AggregateRuntimeBuilder = AggregateRuntime_Builder_Single

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
    EventLogStorage.Selectable,
    EventTopicPublisher.DynamoDbStream,
    EventCollectorChannel,
    AggregateRuntimeBuilder,
    ReventlessCore.Plugin_Helpers.NoopHooksConfig,
  )

  module Spec = Spec
  module AggregateRuntimeBuilder = AggregateRuntimeBuilder

  type api = Inner.api
  type component = Inner.component

  let make = (~api, ~runtime=?, ~opts=?): component => {
    let aggregate = Inner.make(~api, ~runtime?, ~opts?)

    // Extract the event log table name from the aggregate's outputs.
    // EventLog.outputs.resources[0] is the DynamoDB table resource. On the
    // Postgres backend there is no table (resources is empty) — the stable
    // `event_log.log_name` (`<Aggregate>EventLog`) stands in for it, both here
    // and in the entry point's Postgres branch.
    let eventLogTableName = if EventLogBackend.isPostgres() {
      Pulumi.Output.make(Spec.name ++ "EventLog")
    } else {
      let eventLogOutputs = (aggregate->Inner.outputs).eventLog
      let tableResource = eventLogOutputs.resources->Array.getUnsafe(0)
      tableResource.name
    }

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
