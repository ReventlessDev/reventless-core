let componentType = ComponentType.EventTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}
type allOutputs = Js.Dict.t<outputs>

let toUnwrappedOutputs = (outputs: outputs): Pulumi.Output.t<unwrappedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToUnwrappedOutput
  ->Pulumi.Output.apply(resources => {
    let unwrappedOutputs: unwrappedOutputs = {resources: resources}
    unwrappedOutputs
  })

type t

type publish<'id, 'event> = array<Message.event'<'id, 'event>> => Js.Promise.t<unit>
type publishJson = (string, Message.meta, Js.Json.t) => Js.Promise.t<unit>

exception NotPublishedToPublisher(Js.Promise.error)

module type Spec = {
  module Id: ReventlessSpec.Id.T

  @decco
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
