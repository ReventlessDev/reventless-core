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

let send = (queue, queueService, commandJson) => {
  let messageBody = commandJson->toMessageBody
  Effect.tryPromise(
    ~catch=SQS_Error.classify,
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
  ->Effect.retry(SQS_Error.sendRetrySchedule)
  ->Effect.catchAll(err => {
    let msg = SQS_Error.message(err)
    Effect.logError("Util.SQS_Runtime.send: Error: " ++ msg)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
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

let sendMessagesMaxRetries = 5

let sendMessages = (queue, queueService, commandJsons) => {
  let rec attempt = (retry, toSend) =>
    Effect.tryPromise(
      ~catch=SQS_Error.classify,
      () =>
        toSend
        ->Array.map(commandJson => makeEntry(queueService, commandJson))
        ->SQS.sendMessagesParallel(~queueId=queue.id),
    )
    ->Effect.retry(SQS_Error.retrySchedule)
    ->Effect.flatMap(result =>
      switch result {
      | Ok() => Effect.succeed()
      | Error(failedIds) =>
        let commandJsonsToRetry =
          toSend->Array.filter(({meta: {msgId}}) =>
            failedIds->Array.some(failedId => failedId == msgId)
          )
        if retry < sendMessagesMaxRetries {
          Effect.logInfo(
            `Util.SQS_Runtime.sendMessages: ${failedIds->Array.length->Int.toString} failed ids, retrying subset`,
          )
          ->Effect.flatMap(_ => attempt(retry + 1, commandJsonsToRetry))
        } else {
          let ids = failedIds->Array.joinUnsafe(", ")
          Effect.fail(SQS_Error.Permanent(`sendMessages failed for ids: ${ids}`))
        }
      }
    )
  attempt(0, commandJsons)
  ->Effect.catchAll(err => {
    let msg = SQS_Error.message(err)
    Effect.logError(`Util.SQS_Runtime.sendMessages: ${msg}`)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
}

let deleteMessage = async (queue, receiptHandle) => {
  await {
    queueUrl: queue.id,
    receiptHandle,
  }
  ->SQS.DeleteMessageCommand.make
  ->SQS.DeleteMessageCommand.send
}

let deleteMessagesMaxRetries = 5

let deleteMessages = (entries, queue) => {
  let rec attempt = (retry, toDelete) =>
    Effect.tryPromise(
      ~catch=SQS_Error.classify,
      () => SQS.deleteMessagesParallel(~queueId=queue.id, toDelete),
    )
    ->Effect.retry(SQS_Error.retrySchedule)
    ->Effect.flatMap(result =>
      switch result {
      | Ok() => Effect.succeed()
      | Error(failedIds) =>
        let entriesToRetry =
          toDelete
          ->Array.filterWithIndex((_, idx) => {
            let id = idx->Int.toString
            failedIds->Array.some(failedId => failedId == id)
          })
          ->Array.mapWithIndex((entry, idx) => {
            AwsSdk.SQS.DeleteMessageBatchCommand.id: idx->Int.toString,
            receiptHandle: entry.receiptHandle,
          })
        if retry < deleteMessagesMaxRetries {
          Effect.logInfo(
            `Util.SQS_Runtime.deleteMessages: ${failedIds->Array.length->Int.toString} failed ids, retrying subset`,
          )
          ->Effect.flatMap(_ => attempt(retry + 1, entriesToRetry))
        } else {
          let ids = failedIds->Array.joinUnsafe(", ")
          Effect.fail(SQS_Error.Permanent(`deleteMessages failed for ids: ${ids}`))
        }
      }
    )
  attempt(0, entries)
  ->Effect.catchAll(err => {
    let msg = SQS_Error.message(err)
    Effect.logError(`Util.SQS_Runtime.deleteMessages: ${msg}`)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
}

let parseSqsRecord = (record: PulumiAws.SQS.Queue.record) => {
  let eventStr = record.body
  switch eventStr->JSON.parseOrThrow {
  | json => Some(json)
  | exception _err => None
  }
}
