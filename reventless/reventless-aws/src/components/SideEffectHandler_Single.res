module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = ReventlessCore.EventCollectorRuntime_Builder_Single.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)

include ReventlessCore.SideEffectHandler_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  ReventlessCore.EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel),
  EventCollectorRuntimeBuilder,
)
