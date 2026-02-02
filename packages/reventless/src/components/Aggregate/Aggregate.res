let componentType = ComponentType.Aggregate

type t
type rec addEventMapper = (EventTopic.allOutputs, ReventlessSpec.QueryEngine.operations) => outputs
and outputs = {
  name: string,
  commandGenerator: Pulumi.Output.t<CommandGenerator.outputs>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventLog: EventLog.outputs,
  eventMapper?: Pulumi.Output.t<EventMapper.outputs>,
  addEventMapper: addEventMapper,
}
type allOutputs = dict<outputs>
type operations = {publishJsons: CommandTopic.publishJsons}
type component = Component.t<t, outputs, operations>

type name = string

let allEventTopics = allAggregates =>
  Dict.mapValues(allAggregates, aggregate => aggregate.eventLog.eventTopic)
let allCommandTopics = allAggregates =>
  Dict.mapValues(allAggregates, aggregate => aggregate.commandTopic)->Pulumi.Output.allDict

let filterEventTopics = (allAggregates, aggregateNames) =>
  aggregateNames
  ->Belt.Set.String.toArray
  ->Array.filterMap(aggregateName =>
    allAggregates
    ->Dict.get(aggregateName)
    ->Option.map(aggregateOutput => (aggregateName, aggregateOutput.eventLog.eventTopic))
  )
  ->Dict.fromArray

module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec
  module AggregateRuntimeBuilder: AggregateRuntime_Builder.T

  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
