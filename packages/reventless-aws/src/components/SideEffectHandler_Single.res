module EventCollectorChannel = EventCollectorChannel.DynamoDbStream
module RuntimeEnvironment = RuntimeEnvironment.Lambda
module EventCollectorRuntimeBuilder = Reventless.EventCollectorRuntime_Builder_Single.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
)

include Reventless.SideEffectHandler_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  Reventless.EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel),
  EventCollectorRuntimeBuilder,
)
