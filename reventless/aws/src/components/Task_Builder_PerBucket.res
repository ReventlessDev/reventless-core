module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)
module TaskBucket = TaskBucket.S3
module TaskRuntimeBuilder = TaskRuntime_Builder_PerBucket
module SideEffectHandler = SideEffectHandler_PerSideEffectHandler

// Per-bucket task Lambda floor for AWS (large envelope for bulk import/export);
// a plugin.json `runtime` override raises it via `RuntimeHints`.
module Defaults: ReventlessInfra.RuntimeDefaults.T = {
  let memorySize = 4096
  let timeout = 600
}

module Make = (Spec: ReventlessCore.Task.Spec): (
  ReventlessCore.Task.T with module Spec = Spec
) =>
  ReventlessCore.Task_Builder.Make(
    Spec,
    RuntimeEnvironment,
    EventCollectorChannel,
    EventCollectorRuntimeBuilder,
    TaskRuntimeBuilder,
    TaskBucket,
    SideEffectHandler,
    Defaults,
  )
