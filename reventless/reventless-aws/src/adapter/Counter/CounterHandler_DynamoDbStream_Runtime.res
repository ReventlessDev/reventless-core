// open ReventlessInfra.Adapter
// open ReventlessCore.Counter_Runtime
open AwsSdk.DynamoDb.DocumentClient
open Util.DynamoDbStream_Runtime

let addToCounterTarget = (
  table: ReventlessInfra.Adapter.resource,
  {ReventlessInfra.Counter.counterId: counterId, target, targetRef},
) => {
  let tableName = table.name->Pulumi.Output.get
  Effect.logInfo(__MODULE__ ++ ".addToCounterTarget: " ++ counterId ++ " " ++ target->Int.toString)
  ->Effect.flatMap(_ =>
    Effect.tryPromise(
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "addToCounterTarget"),
      () =>
        UpdateCommand.make({
          tableName,
          key: Dict.fromArray([("id", counterId->JSON.Encode.string)]),
          updateExpression: "ADD #count :inc, #total :inc " ++
          ("SET #targets = list_append(if_not_exists(#targets, :empty), :targetSingle), " ++
          "    #targetRefs = list_append(if_not_exists(#targetRefs, :empty), :targetRefSingle)"),
          expressionAttributeNames: [
            ("#count", ReventlessCore.Counter.countFieldName),
            ("#total", "total"),
            ("#targets", "targets"),
            ("#targetRefs", "targetRefs"),
          ]->Dict.fromArray,
          expressionAttributeValues: [
            (":inc", target->Int.toFloat->JSON.Encode.float),
            (":targetSingle", [target->Int.toFloat->JSON.Encode.float]->JSON.Encode.array),
            (":targetRefSingle", [targetRef->JSON.Encode.string]->JSON.Encode.array),
            (":targetRef", targetRef->JSON.Encode.string),
            (":empty", []->JSON.Encode.array),
          ]->Dict.fromArray,
          returnValues: #UPDATED_NEW,
          conditionExpression: "NOT contains(#targetRefs, :targetRef)",
        })->UpdateCommand.send,
    )
  )
  ->Effect.flatMap((updateOutput: UpdateCommand.output) =>
    Effect.logInfo(
      __MODULE__ ++
      `.addToCounterTarget: current count for ${counterId}: ` ++
      updateOutput.attributes
      ->AwsSdk.DynamoDb.DocumentClient.getIntAttribute("count")
      ->Option.mapOr("N/A", v => v->Int.toString),
    )
  )
  ->Effect.catchAll(err =>
    Effect.fail(
      JsError.make(__MODULE__ ++ `.addToCounterTarget Error: Couldn't count on ${tableName}: ${err}`),
    )
  )
  ->Effect.runPromise
}

@schema
type referencesView = {
  id: string,
  inc: int,
}

let handleStreamEvent = (
  ~referencesStream: ReventlessInfra.Adapter.resource,
  ~countsStream: ReventlessInfra.Adapter.resource,
  ~counterHandler: ReventlessCore.Counter_Callback.counterHandler,
  streamEvent: PulumiAws.DynamoDb.Stream.event,
  _,
) => {
  let referencesARN = referencesStream.urn->Pulumi.Output.get
  let countsARN = countsStream.urn->Pulumi.Output.get

  let (dynamoDbRecords, ignoredRecords) =
    streamEvent.records->Array.partition(record =>
      record.eventSource == "aws:dynamodb" &&
        (record.eventSourceARN == referencesARN || record.eventSourceARN == countsARN)
    )

  ignoredRecords->Array.forEach(record =>
    Effect.logWarning(
      __MODULE__ ++
      ": ignoring record from eventSource: " ++
      record.eventSource ++
      " " ++
      record.eventSourceARN,
    )->Effect.runSync
  )

  let (referenceRecords, countRecords) =
    dynamoDbRecords->Array.partition(record => record.eventSourceARN == referencesARN)

  let references = referenceRecords->Array.filterMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(id, newImage) =>
      let inc = switch newImage->S.parseJsonOrThrow(referencesViewSchema) {
      | {inc} => inc
      | exception _err => 1
      }
      Some((id, inc))
    | NewAndOldImage(id, _, _) =>
      Effect.logInfo(
        __MODULE__ ++ " (references): ignoring duplicate id: " ++ id,
      )->Effect.runSync
      None
    | _ => None
    }
  )

  let counts = countRecords->Array.filterMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(_, newImage)
    | NewAndOldImage(_, newImage, _) =>
      Some(newImage)
    | _ => None
    }
  )

  counterHandler(~references, ~counts)
}
