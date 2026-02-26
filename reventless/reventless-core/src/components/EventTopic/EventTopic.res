let componentType = ComponentType.EventTopic

type outputs = Reventless.EventTopic.outputs
type allOutputs = Reventless.EventTopic.allOutputs

type t

type publish<'id, 'event> = array<Message.event'<'id, 'event>> => promise<unit>
type publishJson = Reventless.EventTopic.publishJson

exception NotPublishedToPublisher(exn)

module type T = {
  module Spec: Reventless.EventTopic.T

  type publish = publish<Spec.Id.t, Spec.event>
  type operations = {publish: publish, publishJson: publishJson}
  type component = Component.t<t, outputs, operations>

  let make: (
    ~name: string,
    ~storageResources: array<Reventless.Adapter.resource>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.EventTopic.resolvedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToResolvedOutput
  ->Pulumi.Output.apply(resources => {
    let resolved: ReventlessInterop.EventTopic.resolvedOutputs = {
      resources: resources->Array.map(
        (r: Adapter.resolvedResource): ReventlessInterop.Resource.t => {
          name: r.name,
          id: r.id,
          urn: r.urn,
          info: r.info,
          service: r.service,
        },
      ),
    }
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
    ->Pulumi.Output.apply(topics => Console.log2(description, topics->Array.joinUnsafe(", ")))
}
