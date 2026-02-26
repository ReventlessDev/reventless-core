open Reventless.Adapter

let componentType = ComponentType.EventTopic

type outputs = {resource: resource}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  module Spec: {
    module Id: Reventless.Id.T
    let name: string
    @schema
    type state
  }

  let make: (
    ~name: string,
    ~opts: Pulumi.ComponentResource.options=?,
    ~allQueryDbs: QueryDb.allOutputs,
  ) => component
}

module Adapter = {
  type publisher = {resource: resource}
  type publisherMaker = (
    ~name: string,
    ~opts: Pulumi.CustomResourceOptions.t,
    ~allQueryDbs: QueryDb.allOutputs,
  ) => publisher

  module type Publisher = {
    let make: publisherMaker
  }
}

module Make = (
  Spec: {
    module Id: Reventless.Id.T
    let name: string
    @schema
    type state
  },
  Publisher: Adapter.Publisher,
): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  type constructed
  type construct = (component, string, QueryDb.allOutputs) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
    ~allQueryDbs: QueryDb.allOutputs,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  let construct = (self, name, allQueryDbs) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let publisher = Publisher.make(
      ~name=name->ComponentType.name(componentType),
      ~opts,
      ~allQueryDbs,
    )

    self->setOutputs({resource: publisher.resource})
  }

  let make = (~name, ~opts=?, ~allQueryDbs) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
      ~allQueryDbs,
    )
}
