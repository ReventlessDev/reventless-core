open ReventlessSpec.Adapter

let componentType = ComponentType.EventCollector

type enqueueEvent = (
  . /* ~delay: */ int,
  /* ~id: */ string,
  /* ~message: */ string,
) => Js.Promise.t<unit>

type eventsHandler = (. array<Js.Json.t>) => Js.Promise.t<unit>

module type T = {
  type t
  let make: (
    ~name: string,
    ~eventTopics: ReventlessSpec.EventTopic.allOutputs,
    ~eventsHandler: eventsHandler,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
    unit,
  ) => ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs>

  let enqueueEvent: ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs> => enqueueEvent
}

module Adapter = {
  type connector = {
    resources: array<resource>,
    enqueueEvent: enqueueEvent,
  }
  type connectorMaker = (
    ~name: string,
    ~eventTopics: ReventlessSpec.EventTopic.allOutputs,
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
  type t
  type constructed
  type construct = (ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs>, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs> = "default"

  @obj
  external makeOutputs: (~name: string, ~resources: array<resource>) => ReventlessSpec.EventCollector.outputs = ""
  @send
  external registerOutputs: (ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs>,ReventlessSpec.EventCollector.outputs) => constructed = "registerOutputs"
  @send external setOutputs: (ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs>, ReventlessSpec.EventCollector.outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setEnqueueEvent: (ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs>, enqueueEvent) => unit = "enqueueEvent"
  @get external enqueueEvent: ReventlessSpec.Component.t<t, ReventlessSpec.EventCollector.outputs> => enqueueEvent = "enqueueEvent"

  let enqueueEventFn = connector =>
    (. delay, id, message) => connector.Adapter.enqueueEvent(. delay, id, message)

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
    //Reventless.Logger.logOutput(~loc=__LOC__, name ++ ": policy1", policy1)
    //Reventless.Logger.logOutput(~loc=__LOC__, name ++ ": policy2", policy2)
    let opts = Pulumi.CustomResourceOptions.make(~parent=self->Component.toPulumiResource, ())

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

    self->setEnqueueEvent(connector->enqueueEventFn)

    makeOutputs(~name, ~resources=connector.resources)->setOutputs(self, _)
  }

  let make = (
    ~name,
    ~eventTopics,
    ~eventsHandler,
    ~memorySize=128,
    ~timeout=30,
    ~policy1,
    ~policy2,
    ~opts,
    _,
  ) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~eventTopics, ~eventsHandler, ~memorySize, ~timeout, ~policy1, ~policy2),
      ~opts,
    )
}
