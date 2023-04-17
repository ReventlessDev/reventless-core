include Reventless.SideEffectHandler.Make(
  Reventless.EventCollector.Make(EventCollectorConnector.SQS),
)
