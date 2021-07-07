module Make =
  Reventless.SideEffectHandler.Make(
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        EventCollectorConnector_SQS,
      )
    ),
  );
