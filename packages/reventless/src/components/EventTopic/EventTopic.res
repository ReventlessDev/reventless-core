let componentType = ComponentType.EventTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}
type allOutputs = dict<outputs>

type t

type publish<'id, 'event> = array<Message.event'<'id, 'event>> => promise<unit>
type publishJson = (string, Message.meta, JSON.t) => promise<unit>

exception NotPublishedToPublisher(exn)

module type Spec = {
  module Id: ReventlessSpec.Id.T

  @schema
  type event
}

module type T = {
  module Spec: Spec

  type publish = publish<Spec.Id.t, Spec.event>
  type operations = {publish: publish, publishJson: publishJson}
  type component = Component.t<t, outputs, operations>

  let make: (
    ~name: string,
    ~storageResources: array<ReventlessSpec.Adapter.resource>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

let toUnwrappedOutputs = (outputs: outputs): Pulumi.Output.t<unwrappedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToUnwrappedOutput
  ->Pulumi.Output.apply(resources => {
    let unwrappedOutputs: unwrappedOutputs = {resources: resources}
    unwrappedOutputs
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
