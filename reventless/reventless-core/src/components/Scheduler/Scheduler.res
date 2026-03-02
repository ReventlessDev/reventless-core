let componentType = ComponentType.Scheduler

type outputs = ReventlessInfra.Scheduler.outputs
type createSchedule = ReventlessInfra.Scheduler.createSchedule
type deleteSchedule = ReventlessInfra.Scheduler.deleteSchedule
type operations = ReventlessInfra.Scheduler.operations

type t
type component = Component.t<t, outputs, operations>

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
