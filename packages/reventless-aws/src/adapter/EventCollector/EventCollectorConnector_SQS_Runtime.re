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
       ->Belt.Array.keepMap(record =>
           switch (record##eventSource) {
           | "aws:sqs" =>
             Some(
               AwsSdk.SQS.DeleteMessageBatchEntry.make(
                 ~_Id=record##receiptHandle,
                 ~_ReceiptHandle=record##receiptHandle,
               ),
             )
           | _ => None
           }
         )
       ->AwsSdk.SQS.deleteMessageBatch(~queueId=queue##id->Pulumi.Output.get)
       |> Js.Promise.then_(_ => Js.Promise.resolve())
     );
};
