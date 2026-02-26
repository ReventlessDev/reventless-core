// open Reventless.Adapter
// open ReventlessCore.Counter_Runtime
open AwsSdk.DynamoDb.DocumentClient
open Util.DynamoDbStream_Runtime

let addToCounterTarget = async (
  table: Reventless.Adapter.resource,
  {Reventless.Counter.counterId: counterId, target, targetRef},
) => {
  Console.log3(__MODULE__ ++ ".addToCounterTarget:", counterId, target)
  let tableName = table.name->Pulumi.Output.get
  switch await UpdateCommand.make({
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
  })->UpdateCommand.send {
  | (updateOutput: UpdateCommand.output) =>
    Console.log2(
      __MODULE__ ++ `.addToCounterTarget: current count for ${counterId}:`,
      updateOutput.attributes->AwsSdk.DynamoDb.DocumentClient.getIntAttribute("count"),
    )
  | exception _ =>
    JsError.throwWithMessage(
      __MODULE__ ++ `.addToCounterTarget Error: Couldn't count on ${tableName}`,
    )
  }
}

@schema
type referencesView = {
  id: string,
  inc: int,
}

let handleStreamEvent = (
  ~referencesStream: Reventless.Adapter.resource,
  ~countsStream: Reventless.Adapter.resource,
  ~counterHandler: ReventlessCore.Counter_Callback.counterHandler,
  streamEvent: PulumiAws.DynamoDb.Stream.event,
  _,
) => {
  let referencesARN = referencesStream.urn->Pulumi.Output.get
  let countsARN = countsStream.urn->Pulumi.Output.get

  let (dynamoDbRecords, ignoredRecords) =
    streamEvent.records->Belt.Array.partition(record =>
      record.eventSource == "aws:dynamodb" &&
        (record.eventSourceARN == referencesARN || record.eventSourceARN == countsARN)
    )

  ignoredRecords->Array.forEach(record =>
    Console.log4(
      __MODULE__ ++ ": ignoring record from eventSource:",
      record.eventSource,
      record.eventSourceARN,
      record->JSON.stringifyAny,
    )
  )

  let (referenceRecords, countRecords) =
    dynamoDbRecords->Belt.Array.partition(record => record.eventSourceARN == referencesARN)

  let references = referenceRecords->Array.filterMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(id, newImage) =>
      let inc = switch newImage->S.parseJsonOrThrow(referencesViewSchema) {
      | {inc} => inc
      | exception err =>
        Console.log3(__MODULE__ ++ " (references): error parsing newImage:", newImage, err)
        1
      }
      Some((id, inc))
    | NewAndOldImage(id, _, _) =>
      Console.log2(__MODULE__ ++ " (references): ignoring duplicate id:", id)
      None
    | _ =>
      // Console.log2(__MODULE__ ++ " (references): ignoring record:", record->JSON.stringifyAny)
      None
    }
  )

  let counts = countRecords->Array.filterMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(_, newImage)
    | NewAndOldImage(_, newImage, _) =>
      Some(newImage)
    | _ =>
      // Console.log2(__MODULE__ ++ " (counts): ignoring record:", record->JSON.stringifyAny)
      None
    }
  )

  counterHandler(~references, ~counts)
}
