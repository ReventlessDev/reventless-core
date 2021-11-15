module Make = (Config: Config.T) =>
  Reventless.Counter.Make(
    Config,
    QueryDbStorage_DynamoDbStream,
    CounterHandler_DynamoDbStream,
  );
