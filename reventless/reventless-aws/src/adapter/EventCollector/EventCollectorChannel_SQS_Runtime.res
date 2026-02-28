let handleDynamoDbOrSqsEvent = (queue, handleEvents) =>
  async (event: PulumiAws.Lambda.CallbackFunction.event, _) => {
    let records = event.records
    let jsons = records->Array.filterMap(record =>
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
          Console.log(__MODULE__ ++ ".handleChannelEvent: no NewImage included in Stream event !")
          None
        }
      | eventSource =>
        Console.log2(
          __MODULE__ ++ ".handleChannelEvent: ignoring record from eventSource:",
          eventSource,
        )
        None
      }
    )

    let _ = await (Stream.fromIterable(jsons)->handleEvents->Effect.runPromise)
    let entries =
      records
      ->Array.filter(record =>
        switch record.eventSource {
        | "aws:sqs" => true
        | _ => false
        }
      )
      ->Array.mapWithIndex((
        record,
        idx,
      ): AwsSdk.SQS.DeleteMessageBatchCommand.deleteMessageBatchEntry => {
        id: idx->Int.toString,
        receiptHandle: (record->PulumiAws.SQS.Queue.asRecord).receiptHandle,
      })
    switch entries {
    | [] => ()
    | entries => await Util.SQS_Runtime.deleteMessages(entries, queue)
    }
  }

let handleDynamoDbEvent = handleEvents =>
  async (event: PulumiAws.Lambda.CallbackFunction.event, _) => {
    let records = event.records
    let jsons = records->Array.filterMap(record =>
      switch record.eventSource {
      | "aws:dynamodb" =>
        switch record
        ->PulumiAws.DynamoDb.Stream.asRecord
        ->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
        | NewImage(_, newImage)
        | NewAndOldImage(_, newImage, _) =>
          Some(newImage)
        | _ =>
          Console.log(__MODULE__ ++ ".handleChannelEvent: no NewImage included in Stream event !")
          None
        }
      | eventSource =>
        Console.log2(
          __MODULE__ ++ ".handleChannelEvent: ignoring record from eventSource:",
          eventSource,
        )
        None
      }
    )

    await (Stream.fromIterable(jsons)->handleEvents->Effect.runPromise)
  }

let enqueueEvent = (queue: Util_SQS_Runtime.runtimeQueue, delay, _id, messageBody) => {
  let queueName = queue.name
  Console.log4(__MODULE__ ++ ".enqueueEvent:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendMessage(~delay, messageBody)
}

let enqueueFifoEvent = (queue: Util_SQS_Runtime.runtimeQueue, delay, id, messageBody) => {
  let queueName = queue.name
  Console.log4(__MODULE__ ++ ".enqueueFifoEvent:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendFifoMessage(~delay, ~messageGroupId=id, messageBody)
}
