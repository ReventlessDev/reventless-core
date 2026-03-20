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

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.Aggregate.resolvedOutputs> => {
  let commandGeneratorResolved =
    outputs.commandGenerator->Pulumi.Output.flatMap((cg: ReventlessInfra.CommandGenerator.outputs) =>
      cg.resources
      ->Adapter.resourcesToInterop
      ->Pulumi.Output.apply(resources => {
        let resolved: ReventlessInterop.CommandGenerator.resolvedOutputs = {
          resources: resources,
        }
        resolved
      })
    )
  let commandTopicResolved =
    outputs.commandTopic->Pulumi.Output.flatMap(CommandTopic.toResolvedOutputs)
  let eventLogResolved =
    (
      outputs.eventLog.resources->Adapter.resourcesToInterop,
      outputs.eventLog.eventTopic.resources->Adapter.resourcesToInterop,
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((resources, eventTopicResources)) => {
      let resolved: ReventlessInterop.EventLog.resolvedOutputs = {
        resources: resources,
        eventTopic: {resources: eventTopicResources},
      }
      resolved
    })
  let eventMapperResolved = switch outputs.eventMapper {
  | Some(emOutput) =>
    emOutput
    ->Pulumi.Output.flatMap(EventMapper.toResolvedOutputs)
    ->Pulumi.Output.apply(resolved => Some(resolved))
  | None => Pulumi.Output.make(None)
  }
  (commandGeneratorResolved, commandTopicResolved, eventLogResolved, eventMapperResolved)
  ->Pulumi.Output.all4
  ->Pulumi.Output.apply(((commandGenerator, commandTopic, eventLog, eventMapper)) =>
    switch eventMapper {
    | Some(em) => {
        ReventlessInterop.Aggregate.name: outputs.name,
        commandGenerator,
        commandTopic,
        eventLog,
        eventMapper: em,
      }
    | None => {
        name: outputs.name,
        commandGenerator,
        commandTopic,
        eventLog,
      }
    }
  )
}

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
