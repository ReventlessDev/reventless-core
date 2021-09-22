module Make =
       (Config: Config.T, Target: ReventlessSpec.AggregateSpec.T)
       : (Reventless.EventMapper.T with module Target := Target) =>
  Reventless.EventMapper.Make(
    Target,
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        EventCollectorConnector.DynamoDbStream,
      )
    ),
  );
