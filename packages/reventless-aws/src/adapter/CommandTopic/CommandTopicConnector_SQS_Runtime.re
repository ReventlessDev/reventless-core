let handleQueueEvent = (handleCommands, queue, event, _) => {
  let records = event##_Records;
  let jsons =
    records->Belt.Array.keepMap(record => {
      let commandStr = record##body;
      switch (Js.Json.parseExn(commandStr)) {
      | json => Some(json)
      | exception err =>
        Js.log3(
          "CommandTopicConnector_SQS.handleQueueEvent: Couldn't parse command:",
          commandStr,
          err,
        );
        None;
      };
    });
  handleCommands(. jsons)
  |> Js.Promise.then_(_ =>
       records
       ->Belt.Array.mapWithIndex((idx, record) =>
           AwsSdk.SQS.DeleteMessageBatchEntry.make(
             ~_Id=idx->string_of_int,
             ~_ReceiptHandle=record##receiptHandle,
           )
         )
       ->AwsSdk.SQS.deleteMessageBatch(~queueId=queue##id->Pulumi.Output.get)
       |> Js.Promise.then_(_ => Js.Promise.resolve())
       |> Js.Promise.catch(err =>
            Js.log2(
              __MODULE__ ++ ".handleQueueEvent: Couldn't deleteMessageBatch:",
              err,
            )
            ->Js.Promise.resolve
          )
     );
};

let publish = queue =>
  (. _id, _meta: Reventless.Message.meta, json) =>
    queue->Util_SQS_Runtime.sendMessage(json->Js.Json.stringify);

let publishFifo = queue =>
  (. id, _meta: Reventless.Message.meta, json) =>
    queue->Util_SQS_Runtime.sendFifoMessage(
      ~messageBody=json->Js.Json.stringify,
      ~messageGroupId=id,
      (),
    );
