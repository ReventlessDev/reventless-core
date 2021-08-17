let handleCallbackEvent = (handleEvents, queue, callbackEvent, _) => {
  let records = callbackEvent##_Records->Belt.Option.getWithDefault([||]);
  let jsons =
    records->Belt.Array.keepMap(record =>
      switch (record##eventSource) {
      | "aws:sqs" => record->Util.SQS_Runtime.parseSqsRecord
      | "aws:dynamodb" =>
        record->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecord
      | eventSource =>
        Js.log2(
          "EventCollectorConnector_SQS_Runtime: ignoring record from eventSource:",
          eventSource,
        );
        None;
      }
    );

  handleEvents(. jsons)
  |> Js.Promise.then_(_ =>
       records->Belt.Array.map(record =>
         switch (record##eventSource) {
         | "aws:sqs" =>
           queue->Util.SQS_Runtime.deleteMessage(record##receiptHandle)
         | _ => Js.Promise.resolve()
         }
       )
       |> Js.Promise.all
       |> Js.Promise.then_(_ => Js.Promise.resolve())
     );
};
