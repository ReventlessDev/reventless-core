let handleCallbackEvent = async (
  handleEvents,
  queue,
  callbackEvent: PulumiAws.Lambda.CallbackFunction.event,
  _,
) => {
  let jsons = callbackEvent.records->Belt.Array.keepMap(record =>
    switch record.eventSource {
    | "aws:sqs" => record->PulumiAws.SQS.Queue.asRecord->Util.SQS_Runtime.parseSqsRecord
    | "aws:dynamodb" =>
      switch record
      ->PulumiAws.DynamoDb.Stream.asRecord
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

  switch await handleEvents(jsons) {
  | _ =>
    let entries =
      callbackEvent.records
      ->Belt.Array.keep(record =>
        switch record.eventSource {
        | "aws:sqs" => true
        | _ => false
        }
      )
      ->Belt.Array.mapWithIndex((
        idx,
        record,
      ): AwsSdk.SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry => {
        id: idx->string_of_int,
        receiptHandle: (record->PulumiAws.SQS.Queue.asRecord).receiptHandle,
      })
    switch entries {
    | [] => ()
    | entries => await Util.SQS_Runtime.deleteMessages(entries, queue)
    }
  }
}

let enqueueEvent = (queue: Util_SQS_Runtime.runtimeQueue, delay, _id, messageBody) => {
  let queueName = queue.name
  Js.log4(__MODULE__ ++ ".enqueueEvent:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendMessage(~delay, messageBody)
}

let enqueueFifoEvent = (queue: Util_SQS_Runtime.runtimeQueue, delay, id, messageBody) => {
  let queueName = queue.name
  Js.log4(__MODULE__ ++ ".enqueueFifoEvent:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendFifoMessage(~delay, ~messageGroupId=id, messageBody)
}
