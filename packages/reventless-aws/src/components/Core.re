module Make = (()) =>
  Reventless.Core.Make(
    EventCollectorConnector.DynamoDbStream,
    QueryEngine.DynamoDb,
  );
