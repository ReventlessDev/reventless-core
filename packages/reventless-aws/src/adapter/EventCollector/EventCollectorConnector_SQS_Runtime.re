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
       records
       ->Belt.Array.keep(record =>
           switch (record##eventSource) {
           | "aws:sqs" => true
           | _ => false
           }
         )
       ->Belt.Array.mapWithIndex((idx, record) =>
           AwsSdk.SQS.DeleteMessageBatchEntry.make(
             ~_Id=idx->string_of_int,
             ~_ReceiptHandle=record##receiptHandle,
           )
         )
       ->(
           fun
           | [||] => Js.Promise.resolve()
           | entries =>
             AwsSdk.SQS.deleteMessageBatch(
               ~queueId=queue##id->Pulumi.Output.get,
               entries,
             )
         )
       |> Js.Promise.then_(_ => Js.Promise.resolve())
     );
};
