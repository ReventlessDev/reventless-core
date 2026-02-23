module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = Reventless.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)
module TaskBucket = TaskBucket.S3
module TaskRuntimeBuilder = Reventless.TaskRuntime_Builder_PerBucket.Make(
  RuntimeEnvironment,
  TaskBucket,
)
module SideEffectHandler = SideEffectHandler_PerSideEffectHandler

module Make = (Spec: Reventless.Task.Spec): (
  Reventless.Task.T with module Spec = Spec
) => Reventless.Task_Builder.Make(
  Spec,
  RuntimeEnvironment,
  EventCollectorChannel,
  EventCollectorRuntimeBuilder,
  TaskRuntimeBuilder,
  TaskBucket,
  SideEffectHandler,
)
