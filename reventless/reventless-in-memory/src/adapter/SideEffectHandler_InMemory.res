// In-memory SideEffectHandler.
// In typical test scenarios, TaskSpec.setup returns sideEffects: None,
// so this make function is never called.
//
// When called, the scheduler operations (createSchedule/deleteSchedule) are
// forwarded to the provided ~scheduler; enqueueEvent remains a no-op.

let make = (
  ~name,
  ~sideEffects as _,
  ~allEventTopics as _,
  ~allCommandTopics as _,
  ~targets as _=?,
  ~queryEngine as _,
  ~scheduler: ReventlessInfra.Scheduler.operations,
  ~resourceNaming as _,
  ~memorySize as _=?,
  ~timeout as _=?,
  ~opts=?,
): ReventlessCore.SideEffectHandler.component => {
  let noopEnqueueEvent: ReventlessInfra.EventCollector.enqueueEvent = async (_, _, _) => ()
  let ops: ReventlessCore.SideEffectHandler.operations = {
    enqueueEvent: noopEnqueueEvent,
    // Delegate to the Scheduler adapter, passing empty resources (in-memory has no target queue).
    createSchedule: async schedule => await scheduler.createSchedule([], schedule),
    deleteSchedule: async scheduleName => await scheduler.deleteSchedule([], scheduleName),
  }
  let eventCollectorOutputs: ReventlessInfra.EventCollector.outputs = {
    name,
    resources: [],
  }
  ReventlessCore.Component.make(
    ~componentType=ReventlessCore.SideEffectHandler.componentType->ReventlessCore.ComponentType.toString,
    ~name,
    ~construct=(self, cname) => {
      self->ReventlessCore.Component.setOperations(Pulumi.Output.make(ops))
      self->ReventlessCore.Component.setOutputs({
        ReventlessCore.SideEffectHandler.name: cname,
        eventCollector: eventCollectorOutputs,
      })
    },
    ~opts=opts,
  )
}
