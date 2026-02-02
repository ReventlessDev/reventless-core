open ReventlessSpec.Adapter

let componentType = ComponentType.Scheduler

type outputs = {resource: resource}

type createSchedule = (
  array<Adapter.unwrappedResource>,
  ReventlessSpec.Schedule.schedule,
) => promise<unit>
type deleteSchedule = (array<Adapter.unwrappedResource>, string) => promise<unit>

type operations = {
  createSchedule: createSchedule,
  deleteSchedule: deleteSchedule,
}

type t
type component = Component.t<t, outputs, operations>

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
