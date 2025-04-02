include Reventless.SideEffectHandler_Builder.Make(
  Reventless.EventCollector_Builder.Make(EventCollectorChannel.SQS),
  Reventless.Runtime_Builder_Micro.Make(RuntimeEnvironment_Lambda),
)
