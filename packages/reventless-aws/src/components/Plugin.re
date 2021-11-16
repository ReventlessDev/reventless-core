module Make = (()) =>
  Reventless.Plugin.Make(EventCollectorConnector.SQS, QueryEngine.DynamoDb);
