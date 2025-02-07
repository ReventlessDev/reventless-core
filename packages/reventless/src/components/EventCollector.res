open ReventlessSpec.Adapter
open ReventlessSpec.EventCollector

let componentType = ComponentType.EventCollector

type outputs = {name: string, resources: array<resource>}

type t
type component = Component.t<t, outputs, unit>

type eventsHandler = array<Js.Json.t> => Js.Promise.t<unit>

module type T = {
  let make: (
    ~name: string,
    ~eventTopics: EventTopic.allOutputs,
    ~eventsHandler: eventsHandler,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component

  let enqueueEvent: component => Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent>
}

module Adapter = {
  type connector = {
    resources: array<resource>,
    enqueueEvent: Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent>,
  }
  type connectorMaker = (
    ~name: string,
    ~eventTopics: EventTopic.allOutputs,
    ~handleEvents: eventsHandler,
    ~memorySize: int,
    ~timeout: int,
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => connector

  module type Connector = {
    let make: connectorMaker
  }
}

module Make = (Connector: Adapter.Connector): T => {
  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send
  external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setEnqueueEvent: (component, Pulumi.Output.t<enqueueEvent>) => unit = "enqueueEvent"
  @get
  external enqueueEvent: component => Pulumi.Output.t<enqueueEvent> = "enqueueEvent"

  let construct = (
    ~eventTopics,
    ~eventsHandler,
    ~memorySize,
    ~timeout,
    ~policy1,
    ~policy2,
    self,
    name,
  ) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let connector = Connector.make(
      ~name=name->ComponentType.name(componentType),
      ~eventTopics,
      ~policy1,
      ~policy2,
      ~handleEvents=eventsHandler,
      ~memorySize,
      ~timeout,
      ~opts,
    )

    self->setEnqueueEvent(connector.enqueueEvent)

    self->setOutputs({name, resources: connector.resources})
  }

  let make = (
    ~name,
    ~eventTopics,
    ~eventsHandler,
    ~memorySize=512,
    ~timeout=120,
    ~policy1,
    ~policy2,
    ~opts,
  ) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(
        ~eventTopics,
        ~eventsHandler,
        ~memorySize,
        ~timeout,
        ~policy1,
        ~policy2,
        ...
      ),
      ~opts,
    )
}
