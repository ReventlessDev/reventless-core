include Reventless.SideEffectHandler.Make(
          (
            Reventless.EventCollector.Make(
              Reventless.EventCollector.DefaultPolicies,
              EventCollectorConnector.DynamoDbStream,
            )
          ),
        );

module WithQueue =
  Reventless.SideEffectHandler.Make(
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        EventCollectorConnector.SQS,
      )
    ),
  );

module MakeWithPolicies = (Policies: Reventless.EventCollector.Policies) =>
  Reventless.SideEffectHandler.Make(
    (
      Reventless.EventCollector.Make(
        Policies,
        EventCollectorConnector.DynamoDbStream,
      )
    ),
  );
