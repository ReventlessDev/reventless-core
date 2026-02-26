let componentType = ComponentType.Scheduler

type outputs = Reventless.Scheduler.outputs
type createSchedule = Reventless.Scheduler.createSchedule
type deleteSchedule = Reventless.Scheduler.deleteSchedule
type operations = Reventless.Scheduler.operations

type t
type component = Component.t<t, outputs, operations>

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}
