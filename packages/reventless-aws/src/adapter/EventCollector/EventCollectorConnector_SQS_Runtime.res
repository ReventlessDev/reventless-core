type record = {eventSource: string}
type callbackEvent = {@as("Records") records: array<record>}

external toSqsRecord: record => PulumiAws.SQS.Queue.record = "%identity"
external toDynamoDbStreamRecord: record => AwsSdk.DynamoDb.Stream.Record.t = "%identity"

let handleCallbackEvent = async (handleEvents, queue, callbackEvent: callbackEvent, _) => {
  let jsons = callbackEvent.records->Belt.Array.keepMap(record =>
    switch record.eventSource {
    | "aws:sqs" => record->toSqsRecord->Util.SQS_Runtime.parseSqsRecord
    | "aws:dynamodb" =>
      switch record
      ->toDynamoDbStreamRecord
      ->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
      | NewImage(_, newImage)
      | NewAndOldImage(_, newImage, _) =>
        Some(newImage)
      | _ =>
        Js.log(__MODULE__ ++ ".handleCallbackEvent: no NewImage included in Stream event !")
        None
      }
    | eventSource =>
      Js.log2(__MODULE__ ++ ".handleCallbackEvent: ignoring record from eventSource:", eventSource)
      None
    }
  )

  switch await handleEvents(. jsons) {
  | _ =>
    let entries =
      callbackEvent.records
      ->Belt.Array.keep(record =>
        switch record.eventSource {
        | "aws:sqs" => true
        | _ => false
        }
      )
      ->Belt.Array.mapWithIndex((idx, record) =>
        AwsSdk.SQS.DeleteMessageBatchEntry.make(
          ~_Id=idx->string_of_int,
          ~_ReceiptHandle=(record->toSqsRecord).receiptHandle,
        )
      )
    switch entries {
    | [] => ()
    | entries => await Util.SQS_Runtime.deleteMessages(entries, queue)
    }
  }
}

let enqueueEvent = (queue: PulumiAws.SQS.Queue.t) => (. delay, _id, messageBody) => {
  let queueName = queue.name->Reventless.OutputFailsafeRuntime.get
  Js.log4(__MODULE__ ++ ".enqueueEvent:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendMessage(~delay, messageBody)
}

let enqueueFifoEvent = (queue: PulumiAws.SQS.Queue.t) => (. delay, id, messageBody) => {
  let queueName = queue.name->Reventless.OutputFailsafeRuntime.get
  Js.log4(__MODULE__ ++ ".enqueueFifoEvent:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendFifoMessage(~delay, ~messageGroupId=id, messageBody)
}
