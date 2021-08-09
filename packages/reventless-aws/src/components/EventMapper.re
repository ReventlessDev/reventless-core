module Make =
       (Target: ReventlessSpec.AggregateSpec.T)
       : (Reventless.EventMapper.T with module Target := Target) =>
  Reventless.EventMapper.Make(
    Target,
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        EventCollectorConnector.SQS_FIFO,
      )
    ),
  );
