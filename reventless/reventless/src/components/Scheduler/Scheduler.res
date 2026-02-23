let componentType = ComponentType.Scheduler

type outputs = ReventlessSpec.Scheduler.outputs
type createSchedule = ReventlessSpec.Scheduler.createSchedule
type deleteSchedule = ReventlessSpec.Scheduler.deleteSchedule
type operations = ReventlessSpec.Scheduler.operations

type t
type component = Component.t<t, outputs, operations>

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
