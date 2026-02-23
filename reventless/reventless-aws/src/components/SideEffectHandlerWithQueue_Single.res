module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = Reventless.EventCollectorRuntime_Builder_PerEventCollector.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)

include Reventless.SideEffectHandler_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  Reventless.EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel),
  EventCollectorRuntimeBuilder,
)
