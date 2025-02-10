let componentType = ComponentType.EventTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}
type allOutputs = Js.Dict.t<outputs>

type t

type publish<'id, 'event> = array<Message.event'<'id, 'event>> => Js.Promise.t<unit>
type publishJson = (string, Message.meta, Js.Json.t) => Js.Promise.t<unit>

exception NotPublishedToPublisher(Js.Promise.error)

module type T = {
  module Spec: EventTopic_Runtime.Spec

  type publish = publish<Spec.Id.t, Spec.event>
  type operations = {publish: publish, publishJson: publishJson}
  type component = Component.t<t, outputs, operations>

  let make: (
    ~name: string,
    ~storageResources: array<ReventlessSpec.Adapter.resource>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

module Adapter = {
  type publisher = {
    resources: array<ReventlessSpec.Adapter.resource>,
    publishJson: Pulumi.Output.t<publishJson>,
  }
  type publisherMaker = (
    ~name: string,
    ~storageResources: array<ReventlessSpec.Adapter.resource>,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => publisher

  module type Publisher = {
    let make: publisherMaker
  }
}

module Make = (Spec: EventTopic_Runtime.Spec, Publisher: Adapter.Publisher): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  type publish = publish<Spec.Id.t, Spec.event>
  type operations = {publish: publish, publishJson: publishJson}

  type component = Component.t<t, outputs, operations>

  let construct = (~storageResources, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let publisher = Publisher.make(
      ~name=name->ComponentType.name(componentType),
      ~storageResources,
      ~opts,
    )

    module Runtime = EventTopic_Runtime.Make(Spec)

    self->Component.setOperations(
      publisher.publishJson->Pulumi.Output.apply(publishJson => {
        publishJson,
        publish: Runtime.publish(publishJson, ...),
      }),
    )

    self->Component.setOutputs({resources: publisher.resources})
  }

  let make = (~name, ~storageResources, ~opts=?): component =>
    Component.make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~storageResources, ...),
      ~opts,
    )
}
