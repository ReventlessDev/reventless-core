let parseDynamoDbStreamRecord = record =>
  record##dynamodb
  ->Belt.Option.flatMap(dynamodb => dynamodb##_NewImage)
  ->Belt.Option.map(newImage =>
      AwsSdk.DynamoDb.Converter.unmarshall(~data=newImage##_Message, ())
    )
  ->Belt.Option.map(event => event->Js.Json.object_);
