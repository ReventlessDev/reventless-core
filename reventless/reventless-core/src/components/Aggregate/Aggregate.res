open ReventlessInfra.Aggregate

let componentType = ComponentType.Aggregate

type t
type outputs = ReventlessInfra.Aggregate.outputs
type addEventMapper = ReventlessInfra.Aggregate.addEventMapper
type allOutputs = ReventlessInfra.Aggregate.allOutputs
type operations = ReventlessInfra.Aggregate.operations
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
  module Spec: Reventless.Aggregate.Spec
  module AggregateRuntimeBuilder: AggregateRuntime_Builder.T

  type api
  type component = Component.t<t, outputs, operations>
  let make: (~api: api, ~opts: Pulumi.ComponentResource.options=?) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  let finish: unit => unit
}
