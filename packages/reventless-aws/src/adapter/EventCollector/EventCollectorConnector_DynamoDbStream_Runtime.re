let handleStreamEvent =
    (handleEvents, streamEvent: AwsSdk.DynamoDb_Stream.StreamEvent.t, _) => {
  let records = streamEvent##_Records->Belt.Option.getWithDefault([||]);
  let jsons =
    records->Belt.Array.keepMap(record =>
      record##dynamodb
      ->Belt.Option.flatMap(dynamodb => dynamodb##_NewImage)
      ->Belt.Option.map(newImage =>
          AwsSdk.DynamoDb.Converter.unmarshall(~data=newImage##_Message, ())
        )
      ->Belt.Option.map(event => event->Js.Json.object_)
    );

  handleEvents(. jsons)
  |> Js.Promise.catch(err =>
       Js.Exn.raiseError(err->AwsSdk.Error.ofPromise##message)
     );
};
