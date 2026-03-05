let handleDynamoDbOrSqsEvent = (queue, handleEvents) =>
  (event: PulumiAws.Lambda.CallbackFunction.event, _) => {
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

    Stream.fromIterable(jsons)
    ->handleEvents
    ->Effect.flatMap(_ =>
      Effect.promise(async () => {
        switch entries {
        | [] => ()
        | entries => await Util.SQS_Runtime.deleteMessages(entries, queue)
        }
      })
    )
  }

let handleDynamoDbEvent = handleEvents =>
  (event: PulumiAws.Lambda.CallbackFunction.event, _) => {
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

    Stream.fromIterable(jsons)->handleEvents->Effect.map(_ => ())
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
