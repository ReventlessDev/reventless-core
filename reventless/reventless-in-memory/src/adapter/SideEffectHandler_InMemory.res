// No-op SideEffectHandler for in-memory testing.
// In typical test scenarios, TaskSpec.setup returns sideEffects: None,
// so this make function is never called.

let make = (
  ~name,
  ~sideEffects as _,
  ~allEventTopics as _,
  ~allCommandTopics as _,
  ~targets as _=?,
  ~queryEngine as _,
  ~scheduler as _,
  ~resourceNaming as _,
  ~memorySize as _=?,
  ~timeout as _=?,
  ~opts=?,
): Reventless.SideEffectHandler.component => {
  let noopEnqueueEvent: ReventlessSpec.EventCollector.enqueueEvent = async (_, _, _) => ()
  let noopOps: Reventless.SideEffectHandler.operations = {
    enqueueEvent: noopEnqueueEvent,
    createSchedule: async _ => (),
    deleteSchedule: async _ => (),
  }
  let eventCollectorOutputs: ReventlessSpec.EventCollector.outputs = {
    name,
    resources: [],
  }
  Component.make(
    ~componentType=Reventless.SideEffectHandler.componentType->Reventless.ComponentType.toString,
    ~name,
    ~construct=(self, cname) => {
      self->Component.setOperations(Pulumi.Output.make(noopOps))
      self->Component.setOutputs({Reventless.SideEffectHandler.name: cname, eventCollector: eventCollectorOutputs})
    },
    ~opts=opts,
  )
}
