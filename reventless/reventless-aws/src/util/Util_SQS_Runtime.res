open ReventlessCore.Message
open AwsSdk

type runtimeQueue = {
  id: string,
  name: string,
  arn: string,
}

let toRuntimeQueue = ({id, name, urn}: ReventlessCore.Adapter.resolvedResource) => {
  id,
  name,
  arn: urn,
}

let sendMessage = (queue, ~delay=?, messageBody) =>
  SQS.sendMessage(~queueId=queue.id, ~messageBody, ~delay?)

let sendFifoMessage = (queue, ~delay=?, ~messageGroupId, messageBody) =>
  SQS.sendMessage(~queueId=queue.id, ~messageBody, ~messageGroupId, ~delay?)

let rec send = (queue, queueService, commandJson) => {
  let messageBody = commandJson->toMessageBody
  Effect.tryPromise(
    ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "SQS send"),
    () =>
      if queueService == AWS.SQS_FIFO {
        queue->sendFifoMessage(
          ~messageGroupId=commandJson.id,
          ~delay=?commandJson.delay,
          messageBody,
        )
      } else {
        queue->sendMessage(~delay=?commandJson.delay, messageBody)
      },
  )
  ->Effect.map(_ => ())
  ->Effect.catchAll(errorMsg =>
    Effect.logError(
      "Util.SQS_Runtime.send: Error: failed commandJson: " ++ errorMsg,
    )
    ->Effect.flatMap(_ => {
      let timeout = Math.Int.random(3000, 7000)
      Effect.sleep(Duration.millis(timeout))
      ->Effect.tap(_ =>
        Effect.logInfo(`Retry send after ${timeout->Int.toString} ms ...`)
      )
      ->Effect.flatMap(_ => send(queue, queueService, commandJson))
    })
  )
}

let makeEntry = (queueService, commandJson) => {
  let {id, meta: {msgId: messageId}} = commandJson
  let messageBody = commandJson->toMessageBody

  if queueService == AWS.SQS_FIFO {
    SQS.makeBatchEntryFifo(~groupId=id, ~messageId, ~messageBody, ~delay=?commandJson.delay)
  } else {
    SQS.makeBatchEntry(~messageId, ~messageBody, ~delay=?commandJson.delay)
  }
}

let sendMessages = (queue, queueService, commandJsons) => {
  let rec attempt = toSend =>
    Effect.tryPromise(
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "SQS sendMessages"),
      () =>
        toSend
        ->Array.map(commandJson => makeEntry(queueService, commandJson))
        ->SQS.sendMessagesParallel(~queueId=queue.id),
    )
    ->Effect.flatMap(result =>
      switch result {
      | Ok() => Effect.succeed()
      | Error(failedIds) =>
        Effect.logError(
          "Util.SQS_Runtime.sendMessages: Error: failed ids: " ++
          failedIds->Array.joinUnsafe(", "),
        )
        ->Effect.flatMap(_ => {
          let commandJsonsToRetry =
            toSend->Array.filter(({meta: {msgId}}) =>
              failedIds->Belt.Array.some(failedId => failedId == msgId)
            )
          let timeout = Math.Int.random(3000, 7000)
          Effect.sleep(Duration.millis(timeout))
          ->Effect.tap(_ =>
            Effect.logInfo(
              `Retry sendMessages after ${timeout->Int.toString} ms: ${commandJsonsToRetry->Array.length->Int.toString} commands`,
            )
          )
          ->Effect.flatMap(_ => attempt(commandJsonsToRetry))
        })
      }
    )
    ->Effect.catchAll(errorMsg =>
      Effect.logError(errorMsg)->Effect.flatMap(_ => Effect.fail(errorMsg))
    )
  attempt(commandJsons)
}

let deleteMessage = async (queue, receiptHandle) => {
  await {
    queueUrl: queue.id,
    receiptHandle,
  }
  ->SQS.DeleteMessageCommand.make
  ->SQS.DeleteMessageCommand.send
}

let deleteMessages = (entries, queue) => {
  let rec attempt = toDelete =>
    Effect.tryPromise(
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "SQS deleteMessages"),
      () => SQS.deleteMessagesParallel(~queueId=queue.id, toDelete),
    )
    ->Effect.flatMap(result =>
      switch result {
      | Ok() => Effect.succeed()
      | Error(failedIds) =>
        Effect.logError(
          "Util.SQS_Runtime.deleteMessages: Error: failed ids: " ++
          failedIds->Array.joinUnsafe(", "),
        )
        ->Effect.flatMap(_ => {
          let entriesToRetry =
            toDelete
            ->Belt.Array.keepWithIndex((_, idx) => {
              let id = idx->Int.toString
              failedIds->Belt.Array.some(failedId => failedId == id)
            })
            ->Array.mapWithIndex((entry, idx) => {
              AwsSdk.SQS.DeleteMessageBatchCommand.id: idx->Int.toString,
              receiptHandle: entry.receiptHandle,
            })
          let timeout = Math.Int.random(3000, 7000)
          Effect.sleep(Duration.millis(timeout))
          ->Effect.tap(_ =>
            Effect.logInfo(
              `Retry deleteMessages after ${timeout->Int.toString} ms: ${entriesToRetry->Array.length->Int.toString} entries`,
            )
          )
          ->Effect.flatMap(_ => attempt(entriesToRetry))
        })
      }
    )
    ->Effect.catchAll(errorMsg =>
      Effect.logError(errorMsg)->Effect.flatMap(_ => Effect.fail(errorMsg))
    )
  attempt(entries)
}

let parseSqsRecord = (record: PulumiAws.SQS.Queue.record) => {
  let eventStr = record.body
  switch eventStr->JSON.parseOrThrow {
  | json => Some(json)
  | exception _err => None
  }
}
