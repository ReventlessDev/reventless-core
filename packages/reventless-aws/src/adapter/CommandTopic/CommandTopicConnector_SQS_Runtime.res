let handleQueueEvent = (handleCommands, queue, event, _) => {
  let records = event["_Records"]
  let jsons = records->Belt.Array.keepMap(record => {
    let commandStr = record["body"]
    switch Js.Json.parseExn(commandStr) {
    | json => Some(json)
    | exception err =>
      Js.log3(
        "CommandTopicConnector_SQS.handleQueueEvent: Couldn't parse command:",
        commandStr,
        err,
      )
      None
    }
  })
  let topicItems =
    records
    ->Belt.Array.map(record => record["receiptHandle"])
    ->Belt.Array.zip(jsons)
    ->Belt.Array.map(((reference, command)) => {
      Reventless.CommandTopic.reference,
      command,
    })

  handleCommands(. topicItems)
  ->Js.Promise2.catch(err => {
    Js.log3(__MODULE__ ++ ".handleQueueEvent error:", err, err->Js.Json.stringifyAny)
    Js.Exn.raiseError(
      __MODULE__ ++ ".handleQueueEvent: handleCommands is not allowed to reject (use Belt.Result) !!",
    )
  })
  ->Js.Promise2.then(results =>
    results
    ->Belt.Array.mapWithIndex((idx, result) =>
      switch result {
      | Belt.Result.Ok(reference) =>
        Js.log2(__MODULE__ ++ ".handleQueueEvent: Delete command with ReceiptHandle:", reference)
        AwsSdk.SQS.DeleteMessageBatchEntry.make(
          ~_Id=idx->string_of_int,
          ~_ReceiptHandle=reference,
        )->Some
      | Error(reference) =>
        Js.log2(
          __MODULE__ ++ ".handleQueueEvent: Error: Couldn't handle command with ReceiptHandle:",
          reference,
        )
        None
      }
    )
    ->Belt.Array.keepMap(x => x)
    ->AwsSdk.SQS.deleteMessageBatch(~queueId=queue["id"]->Pulumi.Output.get)
    ->Js.Promise2.then(_ => Js.Promise.resolve())
    ->Js.Promise2.catch(err =>
      Js.log2(
        __MODULE__ ++ ".handleQueueEvent: Error: Couldn't deleteMessageBatch:",
        err,
      )->Js.Promise.resolve
    )
  )
}

let publish = (queue, queueService) => (. jsons) =>
  switch jsons->Belt.Array.length {
  | 0 => Js.log(__MODULE__ ++ ".publish: No commands to send")->Js.Promise.resolve
  | 1 => queue->Util_SQS_Runtime.send(queueService, jsons[0])
  | _ => queue->Util_SQS_Runtime.sendBatch(queueService, jsons)
  }
