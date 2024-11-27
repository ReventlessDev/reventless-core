open ReventlessSpec.Adapter

let componentType = ComponentType.Scheduler

external toOutputs: ReventlessSpec.Scheduler.t => ReventlessSpec.Scheduler.outputs = "%identity"

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => ReventlessSpec.Scheduler.t
}

module Adapter = {
  let publisher = "Publisher"
  type scheduledPublisher = {
    resource: resource,
    create: ReventlessSpec.Scheduler.createSchedule,
    delete: ReventlessSpec.Scheduler.deleteSchedule,
  }
  type scheduledPublisherMaker = (
    ~name: string,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => scheduledPublisher

  module type ScheduledPublisher = {
    let make: scheduledPublisherMaker
  }
}

module Make = (ScheduledPublisher: Adapter.ScheduledPublisher): T => {
  type constructed
  type construct = (ReventlessSpec.Scheduler.t, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => ReventlessSpec.Scheduler.t = "default"

  @obj
  external makeOutputs: (~scheduledPublisher: resource) => ReventlessSpec.Scheduler.outputs = ""

  @send
  external registerOutputs: (
    ReventlessSpec.Scheduler.t,
    ReventlessSpec.Scheduler.outputs,
  ) => constructed = "registerOutputs"
  @send
  external setOutputs: (ReventlessSpec.Scheduler.t, ReventlessSpec.Scheduler.outputs) => unit =
    "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setCreateSchedule: (
    ReventlessSpec.Scheduler.t,
    ReventlessSpec.Scheduler.createSchedule,
  ) => unit = "createSchedule"
  @set
  external setDeleteSchedule: (
    ReventlessSpec.Scheduler.t,
    ReventlessSpec.Scheduler.deleteSchedule,
  ) => unit = "deleteSchedule"

  let construct = (self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Pulumi.Resource.makeFromJs}

    let scheduledPublisher = ScheduledPublisher.make(~name, ~opts)

    self->setCreateSchedule(scheduledPublisher.create)
    self->setDeleteSchedule(scheduledPublisher.delete)

    self->setOutputs(makeOutputs(~scheduledPublisher=scheduledPublisher.resource))
  }

  let make: (~opts: Pulumi.ComponentResource.options=?) => ReventlessSpec.Scheduler.t = (~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=componentType->ComponentType.toName,
      ~construct,
      ~opts,
    )
}
