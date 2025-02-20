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

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
