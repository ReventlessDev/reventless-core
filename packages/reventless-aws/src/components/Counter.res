module Make = (Config: Config.T): Reventless.Counter.T => Reventless.Counter_Builder.Make(
  Config,
  QueryDbStorage_DynamoDbStream,
  CounterHandler_DynamoDbStream,
)
