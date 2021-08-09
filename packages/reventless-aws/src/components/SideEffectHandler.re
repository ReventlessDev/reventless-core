module SideEffectHandler =
  Reventless.SideEffectHandler.Make(
    (
      Reventless.EventCollector.Make(
        Reventless.EventCollector.DefaultPolicies,
        EventCollectorConnector.DynamoDbStream,
      )
    ),
  );

include SideEffectHandler;

module MakeWithPolicies = (Policies: Reventless.EventCollector.Policies) =>
  Reventless.SideEffectHandler.Make(
    (
      Reventless.EventCollector.Make(
        Policies,
        EventCollectorConnector.DynamoDbStream,
      )
    ),
  );
