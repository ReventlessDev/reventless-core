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
type component = Component.t<t, outputs, operations>

module Adapter = {
  let publisher = "Publisher"
  type scheduledPublisher = {
    resource: resource,
    operations: Pulumi.Output.t<operations>,
  }
  type scheduledPublisherMaker = (
    ~name: string,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => scheduledPublisher

  module type ScheduledPublisher = {
    let make: scheduledPublisherMaker
  }
}

module Make = (ScheduledPublisher: Adapter.ScheduledPublisher) => {
  let construct = (self, name): Component.constructed => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let scheduledPublisher = ScheduledPublisher.make(~name, ~opts)

    self->Component.setOperations(scheduledPublisher.operations)
    self->Component.setOutputs({resource: scheduledPublisher.resource})
  }

  let make = (~opts=?): component =>
    Component.make(
      ~componentType=componentType->ComponentType.toString,
      ~name=componentType->ComponentType.toName,
      ~construct,
      ~opts,
    )
}
