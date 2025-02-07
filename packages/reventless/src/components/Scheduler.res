open ReventlessSpec.Adapter

let componentType = ComponentType.Scheduler

type outputs = {resource: resource}

type createSchedule = (
  array<Adapter.unwrappedResource>,
  ReventlessSpec.Schedule.schedule,
) => Js.Promise.t<unit>
type deleteSchedule = (array<Adapter.unwrappedResource>, string) => Js.Promise.t<unit>

type operations = {
  createSchedule: createSchedule,
  deleteSchedule: deleteSchedule,
}

type t
type component = Component.t<t, outputs>

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => component

  let operations: component => operations
}

module Adapter = {
  let publisher = "Publisher"
  type scheduledPublisher = {
    resource: resource,
    operations: operations,
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
  external setOperations: (component, operations) => unit = "operations"
  @get
  external operations: component => operations = "operations"

  let construct = (self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Pulumi.Resource.makeFromJs}

    let scheduledPublisher = ScheduledPublisher.make(~name, ~opts)

    self->setOperations(scheduledPublisher.operations)

    self->setOutputs({resource: scheduledPublisher.resource})
  }

  let make = (~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=componentType->ComponentType.toName,
      ~construct,
      ~opts,
    )
}
