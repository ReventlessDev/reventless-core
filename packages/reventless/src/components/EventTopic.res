let componentType = ComponentType.EventTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}
type allOutputs = Js.Dict.t<outputs>

type t

type publish<'id, 'event> = array<Message.event'<'id, 'event>> => Js.Promise.t<unit>
type publishJson = (string, Message.meta, Js.Json.t) => Js.Promise.t<unit>

exception NotPublishedToPublisher(Js.Promise.error)

module type Spec = {
  module Id: ReventlessSpec.Id.T

  let name: string

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

module Make = (Spec: Spec, Publisher: Adapter.Publisher): (T with module Spec = Spec) => {
  module Spec = Spec

  type publish = publish<Spec.Id.t, Spec.event>
  type operations = {publish: publish, publishJson: publishJson}

  type component = Component.t<t, outputs, operations>

  let publish = publishJson =>
    async events' => {
      let eventCount = events'->Belt.Array.length
      await events'
      ->Belt.Array.mapWithIndex(async (idx, event') => {
        let event'Json = Message.event'_encode(Spec.Id.t_encode, Spec.event_encode, event')

        let id = event'.id
        let idx = idx + 1

        switch await publishJson(id->Spec.Id.toString, event'.meta, event'Json) {
        | exception e =>
          event'Json->Logger.logEvent'Json(
            ~loc=__LOC__,
            ~level=Error,
            `Couldn't publish event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}:`,
          )
          raise(e)
        | _ =>
          event'Json->Logger.logEvent'Json(
            ~loc=__LOC__,
            `Published event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}:`,
          )
        }
      })
      ->Js.Promise.all
      ->Util.Promise.toUnit
    }

  let construct = (~storageResources, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let publisher = Publisher.make(
      ~name=name->ComponentType.name(componentType),
      ~storageResources,
      ~opts,
    )

    self->Component.setOperations(
      publisher.publishJson->Pulumi.Output.apply(publishJson => {
        publishJson,
        publish: publish(publishJson, ...),
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
