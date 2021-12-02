include Reventless.Plugin.Make(
          EventCollectorConnector.SQS,
          QueryEngine.DynamoDb,
        );
