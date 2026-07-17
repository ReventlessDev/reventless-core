let log = Logger.fromEnv()

let componentType = ComponentType.EventTopic

type outputs = ReventlessInfra.EventTopic.outputs
type allOutputs = ReventlessInfra.EventTopic.allOutputs

type t

type publish<'id, 'event> = array<Message.event'<'id, 'event>> => promise<unit>
type publishJson = ReventlessInfra.EventTopic.publishJson
type publishJsonStream = ReventlessInfra.EventTopic.publishJsonStream

exception NotPublishedToPublisher(exn)

module type T = {
  module Spec: ReventlessInfra.EventTopic.T

  type publish = publish<Spec.Id.t, Spec.event>
  type operations = {
    publish: publish,
    publishJson: publishJson,
    publishJsonStream: ReventlessInfra.EventTopic.publishJsonStream,
  }
  type component = Component.t<t, outputs, operations>

  let make: (
    ~name: string,
    ~storageResources: array<ReventlessInfra.Adapter.resource>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.EventTopic.resolvedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToInterop
  ->Pulumi.Output.apply(resources => {
    let resolved: ReventlessInterop.EventTopic.resolvedOutputs = {resources: resources}
    resolved
  })
let allOutputsToResources = allOutputs =>
  allOutputs
  ->Dict.valuesToArray
  ->Array.map((eventTopic: outputs) => eventTopic.resources)
  ->Array.flat

let filter = (allEventTopics: allOutputs, sourceNames) =>
  sourceNames
  ->Belt.Set.String.toArray
  ->Array.filterMap(sourceName =>
    allEventTopics->Dict.get(sourceName)->Option.map(eventTopic => (sourceName, eventTopic))
  )
  ->Dict.fromArray

let log = (eventTopics, description) => {
  let _ =
    eventTopics
    ->Dict.mapValues((eventTopic: outputs) => eventTopic.resources->Array.getUnsafe(0))
    ->Dict.toArray
    ->Array.map(((name, {service})) =>
      service->Pulumi.Output.apply(service => `${name}(${service})`)
    )
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(topics =>
      log.info(~comp="EventTopic", `${description}: ${topics->Array.joinUnsafe(", ")}`)
    )
}
