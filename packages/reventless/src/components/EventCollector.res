let componentType = ComponentType.EventCollector

type enqueueEvent = (
  /* ~delay: */ int,
  /* ~id: */ string,
  /* ~message: */ string,
) => Js.Promise.t<unit>

type t
type outputs = {name: string, resources: array<ReventlessSpec.Adapter.resource>}
type operations = {enqueueEvent: enqueueEvent}
type component = Component.t<t, outputs, operations>

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
}

module Adapter = {
  type connector = {
    resources: array<ReventlessSpec.Adapter.resource>,
    enqueueEvent: Pulumi.Output.t<enqueueEvent>,
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

    self->Component.setOperations(
      connector.enqueueEvent->Pulumi.Output.apply(enqueueEvent => {enqueueEvent: enqueueEvent}),
    )

    self->Component.setOutputs({name, resources: connector.resources})
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
  ): component =>
    Component.make(
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
