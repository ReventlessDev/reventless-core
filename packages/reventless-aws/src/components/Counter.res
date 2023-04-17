module Make = (Config: Config.T): Reventless.Counter.T => Reventless.Counter.Make(
  Config,
  QueryDbStorage_DynamoDbStream,
  CounterHandler_DynamoDbStream,
)
