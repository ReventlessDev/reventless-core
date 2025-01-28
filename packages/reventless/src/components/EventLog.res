open ReventlessSpec.Adapter

let componentType = ComponentType.EventLog

type outputs = {resources: array<resource>, eventTopic: ReventlessSpec.EventTopic.outputs}

type t
type component = ReventlessSpec.Component.t<t, outputs>

exception ReplayError(string)

module type Spec = {
  module Id: ReventlessSpec.Id.T

  let name: string

  @decco
  type event
}

module type T = {
  module Spec: Spec

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component

  let append: component => Pulumi.Output.t<
    ReventlessSpec.EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
  >
  let replay: component => Pulumi.Output.t<ReventlessSpec.EventLog.replay<Spec.Id.t, Spec.event>>
}

module Adapter = {
  type storage = {
    resources: array<resource>,
    append: Pulumi.Output.t<ReventlessSpec.EventLog.append<string, Js.Json.t>>,
    replay: Pulumi.Output.t<ReventlessSpec.EventLog.replay<string, Js.Json.t>>,
  }
  type storageMaker = (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage

  module type Storage = {
    let make: storageMaker
  }
}

module Make = (
  Spec: Spec,
  Storage: Adapter.Storage,
  EventTopicPublisher: EventTopic.Adapter.Publisher,
): (T with module Spec = Spec) => {
  module Spec = Spec

  type constructed
  type construct = (component, string) => constructed

  type append = Pulumi.Output.t<
    ReventlessSpec.EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
  >
  type replay = Pulumi.Output.t<ReventlessSpec.EventLog.replay<Spec.Id.t, Spec.event>>

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set external setAppend: (component, append) => unit = "append"
  @set external setReplay: (component, replay) => unit = "replay"
  @get external append: component => append = "append"
  @get external replay: component => replay = "replay"

  module EventTopic = EventTopic.Make(Spec, EventTopicPublisher)

  let construct = (self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let storage = Storage.make(~name=name->ComponentType.name(componentType), ~opts)

    let eventTopic = EventTopic.make(
      ~name,
      ~storageResources=storage.resources,
      ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
    )

    self->setAppend(
      storage.append->Pulumi.Output.apply(append =>
        EventLog_Runtime.appendFn(
          append,
          Spec.Id.toString,
          Spec.Id.t_encode,
          Spec.event_encode,
          eventTopic->EventTopic.publish,
          Spec.name,
        )
      ),
    )
    self->setReplay(
      storage.replay->Pulumi.Output.apply(replay =>
        EventLog_Runtime.replayFn(replay, Spec.Id.toString, Spec.event_decode)
      ),
    )

    self->setOutputs({
      resources: storage.resources,
      eventTopic: eventTopic->Component.extractOutputs,
    })
  }

  let make = (~name, ~opts=?) =>
    make(~componentType=componentType->ComponentType.toString, ~name, ~construct, ~opts)
}
