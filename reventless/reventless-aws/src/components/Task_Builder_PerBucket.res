module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)
module TaskBucket = TaskBucket.S3
module TaskRuntimeBuilder = ReventlessCore.TaskRuntime_Builder_PerBucket.Make(
  RuntimeEnvironment,
  TaskBucket,
)
module SideEffectHandler = SideEffectHandler_PerSideEffectHandler

module Make = (Spec: ReventlessCore.Task.Spec): (
  ReventlessCore.Task.T with module Spec = Spec
) => ReventlessCore.Task_Builder.Make(
  Spec,
  RuntimeEnvironment,
  EventCollectorChannel,
  EventCollectorRuntimeBuilder,
  TaskRuntimeBuilder,
  TaskBucket,
  SideEffectHandler,
)
