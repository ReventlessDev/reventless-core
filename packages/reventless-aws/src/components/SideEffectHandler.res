include Reventless.SideEffectHandler.Make(
  Reventless.EventCollector_Builder.Make(EventCollectorChannel.DynamoDbStream),
)
