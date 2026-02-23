// In-memory Task builder.

module Make = (Bus: InMemory_Bus.T) => {
  module RuntimeEnvironment = RuntimeEnvironment_InMemory
  module EventCollectorChannel = EventCollectorChannel_InMemory.Make(Bus)
  module EventCollectorRuntimeBuilder = EventCollectorRuntime_Builder_InMemory.Make(
    Bus,
    EventCollectorChannel,
  )
  module TaskRuntimeBuilder = Reventless.TaskRuntime_Builder_PerBucket.Make(
    RuntimeEnvironment,
    TaskBucket_InMemory,
  )
  module SideEffectHandler = SideEffectHandler_InMemory

  module Make = (
    Spec: Reventless.Task.Spec,
  ): (Reventless.Task.T with module Spec = Spec) =>
    Reventless.Task_Builder.Make(
      Spec,
      RuntimeEnvironment,
      EventCollectorChannel,
      EventCollectorRuntimeBuilder,
      TaskRuntimeBuilder,
      TaskBucket_InMemory,
      SideEffectHandler,
    )
}
