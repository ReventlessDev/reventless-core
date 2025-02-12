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
type allOutputs = Js.Dict.t<outputs>
type operations = {publishJsons: ReventlessSpec.CommandTopic.publishJsons}
type component = Component.t<t, outputs, operations>

type name = string

let allEventTopics = allAggregates =>
  Js.Dict.map(aggregate => aggregate.eventLog.eventTopic, allAggregates)

let filterEventTopics = (allAggregates, aggregateNames) =>
  aggregateNames
  ->Belt.Set.String.toArray
  ->Belt.Array.keepMap(aggregateName =>
    allAggregates
    ->Js.Dict.get(aggregateName)
    ->Belt.Option.map(aggregateOutput => (aggregateName, aggregateOutput.eventLog.eventTopic))
  )
  ->Js.Dict.fromArray

module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec

  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
