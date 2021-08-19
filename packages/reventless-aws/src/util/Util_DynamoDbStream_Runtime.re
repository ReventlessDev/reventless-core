let parseDynamoDbStreamRecord = record => {
  let eventJson =
    record##dynamodb
    ->Belt.Option.flatMap(dynamodb => dynamodb##_NewImage)
    ->Belt.Option.map(newImage =>
        AwsSdk.DynamoDb.Converter.unmarshall(~data=newImage, ())
      )
    ->Belt.Option.map(dict =>
        [|
          ("id", dict->Js.Dict.get("id")->Belt.Option.getExn),
          ("meta", dict->Reventless.Message.composeMeta),
          ("event", dict->Js.Dict.get("event")->Belt.Option.getExn),
        |]
        ->Js.Dict.fromArray
        ->Js.Json.object_
      );
  eventJson;
};
