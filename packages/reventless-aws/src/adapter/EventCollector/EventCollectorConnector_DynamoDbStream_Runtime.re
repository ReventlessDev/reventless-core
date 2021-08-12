open Util_DynamoDbStream_Runtime;

let handleStreamEvent = (handleEvents, streamEvent, _) => {
  let records = streamEvent##_Records->Belt.Option.getWithDefault([||]);
  let jsons =
    records->Belt.Array.keepMap(record =>
      switch (record##eventSource) {
      | "aws:dynamodb" => record->parseDynamoDbStreamRecord
      | eventSource =>
        Js.log2(
          "EventCollectorConnector_DynamoDbStream_Runtime: ignoring record from eventSource:",
          eventSource,
        );
        None;
      }
    );

  handleEvents(. jsons)
  |> Js.Promise.catch(err =>
       Js.Exn.raiseError(err->AwsSdk.Error.ofPromise##message)
     );
};
