include Reventless.SideEffectHandler_Builder.Make(
  Reventless.EventCollector_Builder.Make(EventCollectorChannel.SQS),
  RuntimeEnvironment_Lambda,
)
