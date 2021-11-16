include Reventless.Core.Make(
          EventCollectorConnector.DynamoDbStream,
          QueryEngine.DynamoDb,
        );
