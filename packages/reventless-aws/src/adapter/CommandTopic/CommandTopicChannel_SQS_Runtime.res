let handleQueueEvent = (queue, handleCommands) => async (event: PulumiAws.SQS.Queue.event, _) => {
  let records = event.records
  let jsons = records->Array.filterMap(record => {
    let commandStr = record.body
    switch Js.Json.parseExn(commandStr) {
    | json => Some(json)
    | exception err =>
      Js.log3("CommandTopicChannel_SQS.handleQueueEvent: Couldn't parse command:", commandStr, err)
      None
    }
  })
  let topicItems =
    records
    ->Array.map(record => record.receiptHandle)
    ->Belt.Array.zip(jsons)
    ->Array.map(((reference, command)) => {
      Reventless.CommandTopic.reference,
      command,
    })

  switch await handleCommands(topicItems) {
  | exception Js.Exn.Error(err) =>
    Js.log3(__MODULE__ ++ ".handleQueueEvent error:", err, err->Js.Json.stringifyAny)
    Js.Exn.raiseError(
      __MODULE__ ++ ".handleQueueEvent: handleCommands is not allowed to reject (use Belt.Result) !!",
    )
  | results =>
    switch await results
    ->Array.mapWithIndex((result, idx) =>
      switch result {
      | Belt.Result.Ok(reference) =>
        let deleteMessageBatchEntry: AwsSdk.SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry = {
          id: idx->string_of_int,
          receiptHandle: reference,
        }
        deleteMessageBatchEntry->Some
      | Error(reference) =>
        Js.log2(
          __MODULE__ ++ ".handleQueueEvent: Error: Couldn't handle command with ReceiptHandle:",
          reference,
        )
        None
      }
    )
    ->Array.filterMap(x => x)
    ->Util.SQS_Runtime.deleteMessages(queue) {
    | () =>
      Reventless.Logger.debug(~loc=__LOC__, "handleQueueEvent:", "Deleted all commands from queue")
    | exception Js.Exn.Error(e) =>
      Js.log2(
        __MODULE__ ++ ".handleQueueEvent: Error: Couldn't deleteMessageBatch:",
        e->Js.Exn.message,
      )
    }
  }
}

let publishJsons = (queue, queueService) => async jsons =>
  switch jsons->Array.length {
  | 0 => Js.log(__MODULE__ ++ ".publishJsons: No commands to send")
  | 1 => await queue->Util_SQS_Runtime.send(queueService, jsons->Array.getUnsafe(0))
  | _ => await queue->Util_SQS_Runtime.sendMessages(queueService, jsons)
  }
