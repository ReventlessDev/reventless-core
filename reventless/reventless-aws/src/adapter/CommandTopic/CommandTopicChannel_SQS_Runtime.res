let handleQueueEvent = (queue, handleCommands) =>
  async (event: PulumiAws.SQS.Queue.event, _) => {
    let records = event.records
    let jsons = records->Array.filterMap(record => {
      let commandStr = record.body
      switch JSON.parseOrThrow(commandStr) {
      | json => Some(json)
      | exception err =>
        Console.log3(
          "CommandTopicChannel_SQS.handleQueueEvent: Couldn't parse command:",
          commandStr,
          err,
        )
        None
      }
    })
    let topicItems =
      records
      ->Array.map(record => record.receiptHandle)
      ->Belt.Array.zip(jsons)
      ->Array.map(((reference, command)) => {
        ReventlessSpec.CommandTopic.reference,
        command,
      })

    switch await handleCommands(topicItems) {
    | exception JsExn(err) =>
      Console.log3(__MODULE__ ++ ".handleQueueEvent error:", err, err->JSON.stringifyAny)
      JsError.throwWithMessage(
        __MODULE__ ++ ".handleQueueEvent: handleCommands is not allowed to reject (use Belt.Result) !!",
      )
    | results =>
      switch await results
      ->Array.mapWithIndex((result, idx) =>
        switch result {
        | Ok(reference) =>
          let deleteMessageBatchEntry: AwsSdk.SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry = {
            id: idx->Int.toString,
            receiptHandle: reference,
          }
          deleteMessageBatchEntry->Some
        | Error(reference) =>
          Console.log2(
            __MODULE__ ++ ".handleQueueEvent: Error: Couldn't handle command with ReceiptHandle:",
            reference,
          )
          None
        }
      )
      ->Array.filterMap(x => x)
      ->Util.SQS_Runtime.deleteMessages(queue) {
      | () =>
        Reventless.Logger.debug(
          ~loc=__LOC__,
          "handleQueueEvent:",
          "Deleted all commands from queue",
        )
      | exception JsExn(e) =>
        Console.log2(
          __MODULE__ ++ ".handleQueueEvent: Error: Couldn't deleteMessageBatch:",
          e->JsExn.message,
        )
      }
    }
  }

let publishJsons = (queue, queueService) =>
  async jsons =>
    switch jsons->Array.length {
    | 0 => Console.log(__MODULE__ ++ ".publishJsons: No commands to send")
    | 1 => await queue->Util_SQS_Runtime.send(queueService, jsons->Array.getUnsafe(0))
    | _ => await queue->Util_SQS_Runtime.sendMessages(queueService, jsons)
    }
