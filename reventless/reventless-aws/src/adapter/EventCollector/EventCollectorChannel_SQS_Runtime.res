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
        | _ => None
        }
      | _eventSource => None
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
      switch entries {
      | [] => Effect.succeed()
      | entries =>
        Util.SQS_Runtime.deleteMessages(entries, queue)
        ->Effect.catchAll(_err => Effect.succeed())
      }
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
        | _ => None
        }
      | _eventSource => None
      }
    )

    Stream.fromIterable(jsons)->handleEvents->Effect.map(_ => ())
  }

let enqueueEvent = (queue: Util_SQS_Runtime.runtimeQueue, delay, _id, messageBody) =>
  Effect.logInfo(
    __MODULE__ ++ ".enqueueEvent: " ++ delay->Int.toString ++ " " ++ messageBody ++ " " ++ queue.name,
  )
  ->Effect.flatMap(_ =>
    Effect.promise(() => queue->Util_SQS_Runtime.sendMessage(~delay, messageBody))
  )
  ->Effect.map(_ => ())
  ->Effect.runPromise

let enqueueFifoEvent = (queue: Util_SQS_Runtime.runtimeQueue, delay, id, messageBody) =>
  Effect.logInfo(
    __MODULE__ ++ ".enqueueFifoEvent: " ++ delay->Int.toString ++ " " ++ messageBody ++ " " ++ queue.name,
  )
  ->Effect.flatMap(_ =>
    Effect.promise(() =>
      queue->Util_SQS_Runtime.sendFifoMessage(~delay, ~messageGroupId=id, messageBody)
    )
  )
  ->Effect.map(_ => ())
  ->Effect.runPromise
