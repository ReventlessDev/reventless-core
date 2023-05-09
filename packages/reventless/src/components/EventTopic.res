open ReventlessSpec.Adapter

let componentType = ComponentType.EventTopic

type t
type component = ReventlessSpec.Component.t<t, ReventlessSpec.EventTopic.outputs>

type publish<'id, 'event> = (. array<Message.event'<'id, 'event>>) => Js.Promise.t<unit>

exception NotPublishedToPublisher(Js.Promise.error)

module type Spec = {
  module Id: ReventlessSpec.Id.T

  let name: string

  @decco
  type event
}

module type T = {
  module Spec: Spec

  let make: (
    ~name: string,
    ~storageResources: array<resource>,
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit,
  ) => component

  let publish: component => publish<Spec.Id.t, Spec.event>
}

module Adapter = {
  type publisher = {
    resources: array<resource>,
    publish: (. string, Message.meta, Js.Json.t) => Js.Promise.t<unit>,
  }
  type publisherMaker = (
    ~name: string,
    ~storageResources: array<resource>,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => publisher

  module type Publisher = {
    let make: publisherMaker
  }
}

module Make = (Spec: Spec, Publisher: Adapter.Publisher): (T with module Spec = Spec) => {
  module Spec = Spec

  type constructed
  type construct = (component, string) => constructed

  type publish = publish<Spec.Id.t, Spec.event>

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => component = "default"

  @obj external makeOutputs: (~resources: array<resource>) => ReventlessSpec.EventTopic.outputs = ""

  @send
  external registerOutputs: (component, ReventlessSpec.EventTopic.outputs) => constructed =
    "registerOutputs"
  @send external setOutputs: (component, ReventlessSpec.EventTopic.outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set external setPublish: (component, publish) => unit = "publish"
  @get external publish: component => publish = "publish"

  let publishFn = (publisher: Adapter.publisher, name) => async (. events') => {
    let eventCount = events'->Belt.Array.length
    await events'
    ->Belt.Array.mapWithIndex(async (idx, event') => {
      let json = Message.event'_encode(Spec.Id.t_encode, Spec.event_encode, event')

      let id = event'.id
      let eventName: string =
        event'.event
        ->Spec.event_encode
        ->Util.Decco.Json.variantName
        ->Belt.Option.getWithDefault("Could not get event-name!")
      let idx = idx + 1

      switch await publisher.publish(. id->Spec.Id.toString, event'.meta, json) {
      | exception e =>
        Js.log(
          `EventTopic: Couldn't publish event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}: ${eventName}(${id->Spec.Id.toString}) to ${name}`,
        )
        raise(e)
      | _ =>
        let event = json->Js.Json.stringify
        Js.log(
          `EventTopic: Published event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString}: ${eventName}(${id->Spec.Id.toString}) to ${name}: ${event}`,
        )
      }
    })
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }

  let construct = (~storageResources, self, name) => {
    let opts = Pulumi.CustomResourceOptions.make(~parent=self->Component.toPulumiResource, ())

    let publisher = Publisher.make(
      ~name=name->ComponentType.name(componentType),
      ~storageResources,
      ~opts,
    )

    self->setPublish(publisher->publishFn(name))

    self->setOutputs(makeOutputs(~resources=publisher.resources))
  }

  let make = (~name, ~storageResources, ~opts=?, _) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~storageResources),
      ~opts,
    )
}
