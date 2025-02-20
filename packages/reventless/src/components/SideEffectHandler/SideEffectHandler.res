module ReventlessEventCollector = EventCollector

let componentType = ComponentType.SideEffectHandler

type t
type outputs = {name: string, eventCollector: EventCollector.outputs}
type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  createSchedule: ReventlessSpec.Schedule.create,
  deleteSchedule: ReventlessSpec.Schedule.delete,
}
type component = Component.t<t, outputs, operations>

type sideEffects = array<module(ReventlessSpec.SideEffect.T)>

module type T = {
  let make: (
    ~name: string,
    ~sideEffects: sideEffects,
    ~allEventTopics: EventTopic.allOutputs,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    ~scheduler: Scheduler.operations,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => component
}
