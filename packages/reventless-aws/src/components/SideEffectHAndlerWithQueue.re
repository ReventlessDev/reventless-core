include Reventless.SideEffectHandler.Make(
          (
            Reventless.EventCollector.Make(
              Reventless.EventCollector.DefaultPolicies,
              EventCollectorConnector.SQS,
            )
          ),
        );
