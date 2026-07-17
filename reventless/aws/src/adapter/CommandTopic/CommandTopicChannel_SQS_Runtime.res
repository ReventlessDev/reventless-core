let handleQueueEvent = (
  queue,
  handleJsonCommands: ReventlessCore.CommandTopic.jsonCommandsHandler,
) =>
  (event: PulumiAws.SQS.Queue.event, _) => {
    let records = event.records
    let jsons = records->Array.filterMap(record => {
      let commandStr = record.body
      switch JSON.parseOrThrow(commandStr) {
      | json => Some(json)
      | exception _err => None
      }
    })
    let topicItems =
      records
      ->Array.map(record => record.receiptHandle)
      ->Array.zip(jsons)
      ->Array.map(((reference, command)) => {
        ReventlessInfra.CommandTopic.reference,
        command,
      })

    Stream.fromIterable(topicItems)
    ->handleJsonCommands
    ->Effect.flatMap(results => {
      let deleteEntries =
        results
        ->Array.mapWithIndex(
          (result, idx) =>
            switch result {
            | Ok(reference) =>
              let deleteMessageBatchEntry: AwsSdk.SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry = {
                id: idx->Int.toString,
                receiptHandle: reference,
              }
              deleteMessageBatchEntry->Some
            | Error(reference) =>
              ReventlessCore.EffectLogger.logError(
                ~comp=__MODULE__,
                "handleQueueEvent: Couldn't handle command with ReceiptHandle: " ++ reference,
              )->Effect.runSync
              None
            },
        )
        ->Array.filterMap(x => x)

      switch deleteEntries {
      | [] => Effect.succeed()
      | entries =>
        Util.SQS_Runtime.deleteMessages(entries, queue)
        ->Effect.tap(_ => ReventlessCore.EffectLogger.logInfo(~comp=__MODULE__, "handleQueueEvent: Deleted all commands from queue"))
        ->Effect.catchAll(errorMsg =>
          ReventlessCore.EffectLogger.logError(
            ~comp=__MODULE__,
            "handleQueueEvent: Couldn't deleteMessageBatch: " ++ errorMsg,
          )
        )
      }
    })
  }

let publishJsons = (queue, queueService) =>
  async jsons =>
    switch jsons->Array.length {
    | 0 =>
      ReventlessCore.EffectLogger.logInfo(~comp=__MODULE__, "publishJsons: No commands to send")->Effect.runPromise->ignore
    | 1 =>
      await queue->Util_SQS_Runtime.send(queueService, jsons->Array.getUnsafe(0))->Effect.runPromise
    | _ =>
      await queue
      ->Util_SQS_Runtime.sendMessages(queueService, jsons)
      ->Effect.runPromise
    }
