module Make =
  Reventless.SideEffectHandler.Make(
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        ReventlessAws.EventCollectorConnector_SQS,
      )
    ),
  );
