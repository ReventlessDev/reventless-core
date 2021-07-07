module Make =
  Reventless.SideEffectHandler.Make(
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        EventCollectorConnector_SQS,
      )
    ),
  );

module MakeWithPolicies = (Policies: Reventless.EventCollector.Policies) =>
  Reventless.SideEffectHandler.Make(
    (Reventless.EventCollector.Make(Policies, EventCollectorConnector_SQS)),
  );
