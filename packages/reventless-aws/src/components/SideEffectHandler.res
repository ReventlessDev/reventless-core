include Reventless.SideEffectHandler_Builder.Make(
  Reventless.EventCollector_Builder.Make(EventCollectorChannel.DynamoDbStream),
  RuntimeEnvironment_Lambda,
)
