module Make =
       (
         Config: Config.T,
         Handler: Reventless.AtomicCounter.Handler,
         Target: ReventlessSpec.AggregateSpec.T,
       )
       : (Reventless.EventMapper.T with module Target := Target) =>
  Reventless.EventMapper.Make(
    Target,
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        EventCollectorConnector.DynamoDbStream,
      )
    ),
    (
      Reventless.AtomicCounter.Make(
        Config,
        Handler,
        QueryDbStorage_DynamoDbStream,
      )
    ),
  );
