// In-memory Task builder.

module Make = (Bus: LocalBus.T) => {
  module RuntimeEnvironment = LocalRuntimeEnvironment
  module EventCollectorChannel = LocalEventCollectorChannel.Make(Bus)
  module EventCollectorRuntimeBuilder = LocalEventCollectorRuntime_Builder.Make(
    Bus,
    EventCollectorChannel,
  )
  module TaskRuntimeBuilder = ReventlessCore.TaskRuntime_Builder_PerBucket.Make(
    RuntimeEnvironment,
    LocalTaskBucket,
  )
  module SideEffectHandler = LocalSideEffectHandler

  module Make = (
    Spec: ReventlessCore.Task.Spec,
  ): (ReventlessCore.Task.T with module Spec = Spec) =>
    ReventlessCore.Task_Builder.Make(
      Spec,
      RuntimeEnvironment,
      EventCollectorChannel,
      EventCollectorRuntimeBuilder,
      TaskRuntimeBuilder,
      LocalTaskBucket,
      SideEffectHandler,
    )
}
