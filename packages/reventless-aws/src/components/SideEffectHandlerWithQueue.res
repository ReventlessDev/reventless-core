module EventCollectorChannel = EventCollectorChannel.SQS
module RuntimeEnvironment = RuntimeEnvironment.Lambda

include Reventless.SideEffectHandler_Builder.Make(
  RuntimeEnvironment,
  EventCollectorChannel,
  Reventless.EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel),
  Reventless.PluginRuntime_Builder_Micro.Make(RuntimeEnvironment, EventCollectorChannel),
)
