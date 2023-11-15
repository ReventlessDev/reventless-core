open Reventless.Message
open AwsSdk

let service = "SQS"

let sendMessage = (queue: PulumiAws.SQS.Queue.t, ~delay=?, messageBody) =>
  SQS.sendMessage(~queueId=queue["id"]->Pulumi.Output.get, ~messageBody, ~delay?, ())

let sendFifoMessage = (queue: PulumiAws.SQS.Queue.t, ~delay=?, ~messageGroupId, messageBody) =>
  SQS.sendMessage(
    ~queueId=queue["id"]->Pulumi.Output.get,
    ~messageBody,
    ~messageGroupId,
    ~delay?,
    (),
  )

let rec send = async (queue, queueService, {id, delay} as commandJson) => {
  let messageBody = commandJson->toMessageBody
  try await (
    if queueService == Util_SQS_FIFO.service {
      queue->sendFifoMessage(~messageGroupId=id, ~delay?, messageBody)
    } else {
      queue->sendMessage(~delay?, messageBody)
    }
  ) catch {
  | Js.Exn.Error(e) =>
    Js.log3("Util.SQS_Runtime.send: Error: failed commandJson:", commandJson, e->Js.Exn.message)
    let timeout = Js.Math.random_int(3000, 7000)
    await Reventless.Util.Promise.finishTimeout(timeout)
    Js.log(`Retry send after ${timeout->Js.Int.toString} ms ...`)
    await send(queue, queueService, commandJson)
  }
}

let makeEntry = (queueService, {id, meta: {msgId: messageId, service}, delay} as commandJson) => {
  let messageBody = commandJson->toMessageBody
  Js.log(`Publishing command to Aggregate ${service}: ${messageBody} id: ${id}`)
  if queueService == Util_SQS_FIFO.service {
    SQS.makeBatchEntryFifo(~groupId=id, ~messageId, ~messageBody, ~delay)
  } else {
    SQS.makeBatchEntry(~messageId, ~messageBody, ~delay)
  }
}

let rec sendMessages = async (queue, queueService, commandJsons) => {
  switch await commandJsons
  ->Belt.Array.map(commandJson => makeEntry(queueService, commandJson))
  ->SQS.sendMessagesParallel(~queueId=queue["id"]->Pulumi.Output.get) {
  | Ok() => ()
  | Error(failedIds) =>
    Js.log2("Util.SQS_Runtime.sendMessages: Error: failed ids:", failedIds)
    let commandJsonsToRetry =
      commandJsons->Belt.Array.keep(({meta: {msgId}}) =>
        failedIds->Belt.Array.some(failedId => failedId == msgId)
      )
    let timeout = Js.Math.random_int(3000, 7000)
    await Reventless.Util.Promise.finishTimeout(timeout)
    Js.log(`Retry sendMessages after ${timeout->Js.Int.toString} ms ...`)
    await sendMessages(queue, queueService, commandJsonsToRetry)
  }
}

let rec deleteMessage = async (queue, receiptHandle) =>
  try await SQS.deleteMessage(~queueId=queue["id"]->Pulumi.Output.get, ~receiptHandle) catch {
  | Js.Exn.Error(e) =>
    Js.log3(
      "Util.SQS_Runtime.deleteMessage: Error: failed receiptHandle:",
      receiptHandle,
      e->Js.Exn.message,
    )
    let timeout = Js.Math.random_int(3000, 7000)
    await Reventless.Util.Promise.finishTimeout(timeout)
    Js.log(`Retry deleteMessage after ${timeout->Js.Int.toString} ms ...`)
    await deleteMessage(queue, receiptHandle)
  }

let rec deleteMessages = async (entries, queue) =>
  switch await SQS.deleteMessagesParallel(~queueId=queue["id"]->Pulumi.Output.get, entries) {
  | Ok() => ()
  | Error(failedIds) =>
    Js.log2("Util.SQS_Runtime.deleteMessages: Error: failed ids:", failedIds)
    let entriesToRetry =
      entries
      ->Belt.Array.keepWithIndex((_, idx) => {
        let id = idx->Js.Int.toString
        failedIds->Belt.Array.some(failedId => failedId == id)
      })
      ->Belt.Array.mapWithIndex((idx, entry) =>
        AwsSdk.SQS.DeleteMessageBatchEntry.make(
          ~_Id=idx->Js.Int.toString,
          ~_ReceiptHandle=entry["_ReceiptHandle"],
        )
      )
    let timeout = Js.Math.random_int(3000, 7000)
    await Reventless.Util.Promise.finishTimeout(timeout)
    Js.log2(`Retry deleteMessages after ${timeout->Js.Int.toString} ms:`, entriesToRetry)
    await deleteMessages(entriesToRetry, queue)
  }

let parseSqsRecord = record => {
  let eventStr = record["body"]
  switch eventStr->Js.Json.parseExn {
  | json => Some(json)
  | exception err =>
    Js.log3("parseSqsRecord: Couldn't parse event:", eventStr, err)
    None
  }
}

@obj
external makeQueue: (
  ~arn: Pulumi.Output.t<string>,
  ~name: Pulumi.Output.t<string>,
  ~id: Pulumi.Output.t<string>,
) => PulumiAws.SQS.Queue.t = ""

let fromResource = (resource: ReventlessSpec.Adapter.resource) =>
  makeQueue(~id=resource["id"], ~name=resource["name"], ~arn=resource["urn"])

let findResource = resources => resources->Reventless.Util.AdapterRuntime.findResource(service)

let findUnwrappedResource = resources =>
  resources->Reventless.Util.AdapterRuntime.findUnwrappedResource(service)
