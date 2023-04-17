module Record = {
  type t = {"body": string, "eventSource": string}

  external toSqsRecord: t => PulumiAws.SQS.Queue.Record.t = "%identity"
  external toDynamoDbRecord: t => AwsSdk.DynamoDb.Stream.Record.t = "%identity"
}

let handleCallbackEvent = (handleEvents, queue, callbackEvent, _) => {
  let records = callbackEvent["_Records"]->Belt.Option.getWithDefault([])
  let jsons = records->Belt.Array.keepMap(record =>
    switch record["eventSource"] {
    | "aws:sqs" => record->Record.toSqsRecord->Util.SQS_Runtime.parseSqsRecord
    | "aws:dynamodb" =>
      switch record
      ->Record.toDynamoDbRecord
      ->Util.DynamoDbStream_Runtime.parseDynamoDbStreamRecordEvent {
      | NewImage(_, newImage)
      | NewAndOldImage(_, newImage, _) =>
        Some(newImage)
      | _ =>
        Js.log(__MODULE__ ++ ".handleCallbackEvent: no NewImage included in Stream event !")
        None
      }
    | eventSource =>
      Js.log2("EventCollectorConnector_SQS_Runtime: ignoring record from eventSource:", eventSource)
      None
    }
  )

  handleEvents(. jsons) |> Js.Promise.then_(_ =>
    records
    ->Belt.Array.keep(record =>
      switch record["eventSource"] {
      | "aws:sqs" => true
      | _ => false
      }
    )
    ->Belt.Array.mapWithIndex((idx, record) =>
      AwsSdk.SQS.DeleteMessageBatchEntry.make(
        ~_Id=idx->string_of_int,
        ~_ReceiptHandle=(record->Record.toSqsRecord)["receiptHandle"],
      )
    )
    ->(
      x =>
        switch x {
        | [] => Js.Promise.resolve()
        | entries => AwsSdk.SQS.deleteMessageBatch(~queueId=queue["id"]->Pulumi.Output.get, entries)
        }
    ) |> Js.Promise.then_(_ => Js.Promise.resolve())
  )
}

let enqueueEvent = (queue, . delay, _id, messageBody) => {
  let queueName = queue["name"]->Reventless.OutputFailsafeRuntime.get
  Js.log4(__MODULE__ ++ ".enqueueMessage:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendMessage(~delay, messageBody)
}

let enqueueFifoEvent = (queue, . delay, id, messageBody) => {
  let queueName = queue["name"]->Reventless.OutputFailsafeRuntime.get
  Js.log4(__MODULE__ ++ ".enqueueMessage:", delay, messageBody, queueName)
  queue->Util_SQS_Runtime.sendFifoMessage(~delay, ~messageGroupId=id, messageBody)
}
