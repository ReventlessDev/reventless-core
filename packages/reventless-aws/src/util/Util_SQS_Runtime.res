open Reventless.Message
open AwsSdk

type runtimeQueue = {
  id: string,
  name: string,
  arn: string,
}

let toRuntimeQueue = ({id, name, urn}: Reventless.Adapter.unwrappedResource) => {
  id,
  name,
  arn: urn,
}

let sendMessage = (queue, ~delay=?, messageBody) =>
  SQS.sendMessage(~queueId=queue.id, ~messageBody, ~delay?)

let sendFifoMessage = (queue, ~delay=?, ~messageGroupId, messageBody) =>
  SQS.sendMessage(~queueId=queue.id, ~messageBody, ~messageGroupId, ~delay?)

let rec send = async (queue, queueService, {id, delay} as commandJson) => {
  let messageBody = commandJson->toMessageBody
  try await (
    if queueService == AWS.SQS_FIFO {
      queue->sendFifoMessage(~messageGroupId=id, ~delay, messageBody)
    } else {
      queue->sendMessage(~delay, messageBody)
    }
  ) catch {
  | JsExn(e) =>
    Console.log3("Util.SQS_Runtime.send: Error: failed commandJson:", commandJson, e->JsExn.message)
    let timeout = Math.Int.random(3000, 7000)
    await Reventless.Util.Promise.finishTimeout(timeout)
    Console.log(`Retry send after ${timeout->Int.toString} ms ...`)
    await send(queue, queueService, commandJson)
  }
}

let makeEntry = (queueService, {id, meta: {msgId: messageId}, delay} as commandJson) => {
  let messageBody = commandJson->toMessageBody

  // Console.log(`Publishing command to Aggregate ${service}: ${messageBody} id: ${CommandTopic: Published commands:id}`)
  if queueService == AWS.SQS_FIFO {
    SQS.makeBatchEntryFifo(~groupId=id, ~messageId, ~messageBody, ~delay)
  } else {
    SQS.makeBatchEntry(~messageId, ~messageBody, ~delay)
  }
}

let rec sendMessages = async (queue, queueService, commandJsons) => {
  switch await commandJsons
  ->Array.map(commandJson => makeEntry(queueService, commandJson))
  ->SQS.sendMessagesParallel(~queueId=queue.id) {
  | Ok() => ()
  | Error(failedIds) =>
    Console.log2("Util.SQS_Runtime.sendMessages: Error: failed ids:", failedIds)
    let commandJsonsToRetry =
      commandJsons->Array.filter(({meta: {msgId}}) =>
        failedIds->Belt.Array.some(failedId => failedId == msgId)
      )
    let timeout = Math.Int.random(3000, 7000)
    await Reventless.Util.Promise.finishTimeout(timeout)
    Console.log2(`Retry sendMessages after ${timeout->Int.toString} ms:`, commandJsonsToRetry)
    await sendMessages(queue, queueService, commandJsonsToRetry)
  }
}

let deleteMessage = async (queue, receiptHandle) => {
  await {
    queueUrl: queue.id,
    receiptHandle,
  }
  ->SQS.DeleteMessageCommand.make
  ->SQS.DeleteMessageCommand.send
}

let rec deleteMessages = async (entries, queue) =>
  switch await SQS.deleteMessagesParallel(~queueId=queue.id, entries) {
  | Ok() => ()
  | Error(failedIds) =>
    Console.log2("Util.SQS_Runtime.deleteMessages: Error: failed ids:", failedIds)
    let entriesToRetry =
      entries
      ->Belt.Array.keepWithIndex((_, idx) => {
        let id = idx->Int.toString
        failedIds->Belt.Array.some(failedId => failedId == id)
      })
      ->Array.mapWithIndex((entry, idx) => {
        AwsSdk.SQS.DeleteMessageBatchCommand.id: idx->Int.toString,
        receiptHandle: entry.receiptHandle,
      })
    let timeout = Math.Int.random(3000, 7000)
    await Reventless.Util.Promise.finishTimeout(timeout)
    Console.log2(`Retry deleteMessages after ${timeout->Int.toString} ms:`, entriesToRetry)
    await deleteMessages(entriesToRetry, queue)
  }

let parseSqsRecord = (record: PulumiAws.SQS.Queue.record) => {
  let eventStr = record.body
  Console.log2("parseSqsRecord: eventStr:", eventStr)
  switch eventStr->JSON.parseOrThrow {
  | json => Some(json)
  | exception err =>
    Console.log3("parseSqsRecord: Couldn't parse event:", eventStr, err)
    None
  }
}
