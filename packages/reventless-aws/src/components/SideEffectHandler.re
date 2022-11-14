include Reventless.SideEffectHandler.Make(
          (
            Reventless.EventCollector.Make(
              Reventless.EventCollector.DefaultPolicies,
              EventCollectorConnector.DynamoDbStream,
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
