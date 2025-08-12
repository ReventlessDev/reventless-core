// open ReventlessSpec.Adapter
// open Reventless.Counter_Runtime
open AwsSdk.DynamoDb.DocumentClient
open Util.DynamoDbStream_Runtime

let addToCounterTarget = async (
  table: ReventlessSpec.Adapter.resource,
  {Reventless.Counter.counterId: counterId, target, targetRef},
) => {
  Js.log3(__MODULE__ ++ ".addToCounterTarget:", counterId, target)
  let tableName = table.name->Pulumi.Output.get
  switch await UpdateCommand.make({
    tableName,
    key: Js.Dict.fromArray([("id", counterId->Js.Json.string)]),
    updateExpression: "ADD #count :inc, #total :inc " ++
    ("SET #targets = list_append(if_not_exists(#targets, :empty), :targetSingle), " ++
    "    #targetRefs = list_append(if_not_exists(#targetRefs, :empty), :targetRefSingle)"),
    expressionAttributeNames: [
      ("#count", Reventless.Counter.countFieldName),
      ("#total", "total"),
      ("#targets", "targets"),
      ("#targetRefs", "targetRefs"),
    ]->Js.Dict.fromArray,
    expressionAttributeValues: [
      (":inc", target->Int.toFloat->Js.Json.number),
      (":targetSingle", [target->Int.toFloat->Js.Json.number]->Js.Json.array),
      (":targetRefSingle", [targetRef->Js.Json.string]->Js.Json.array),
      (":targetRef", targetRef->Js.Json.string),
      (":empty", []->Js.Json.array),
    ]->Js.Dict.fromArray,
    returnValues: #UPDATED_NEW,
    conditionExpression: "NOT contains(#targetRefs, :targetRef)",
  })->UpdateCommand.send {
  | (updateOutput: UpdateCommand.output) =>
    Js.log2(
      __MODULE__ ++ `.addToCounterTarget: current count for ${counterId}:`,
      updateOutput.attributes->AwsSdk.DynamoDb.DocumentClient.getIntAttribute("count"),
    )
  | exception _ =>
    Js.Exn.raiseError(__MODULE__ ++ `.addToCounterTarget Error: Couldn't count on ${tableName}`)
  }
}

@schema
type referencesView = {
  id: string,
  inc: int,
}

let handleStreamEvent = (
  ~referencesStream: ReventlessSpec.Adapter.resource,
  ~countsStream: ReventlessSpec.Adapter.resource,
  ~counterHandler: Reventless.Counter_Callback.counterHandler,
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
    Js.log4(
      __MODULE__ ++ ": ignoring record from eventSource:",
      record.eventSource,
      record.eventSourceARN,
      record->Js.Json.stringifyAny,
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
        Js.log3(__MODULE__ ++ " (references): error parsing newImage:", newImage, err)
        1
      }
      Some((id, inc))
    | NewAndOldImage(id, _, _) =>
      Js.log2(__MODULE__ ++ " (references): ignoring duplicate id:", id)
      None
    | _ =>
      // Js.log2(__MODULE__ ++ " (references): ignoring record:", record->Js.Json.stringifyAny)
      None
    }
  )

  let counts = countRecords->Array.filterMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(_, newImage)
    | NewAndOldImage(_, newImage, _) =>
      Some(newImage)
    | _ =>
      // Js.log2(__MODULE__ ++ " (counts): ignoring record:", record->Js.Json.stringifyAny)
      None
    }
  )

  counterHandler(~references, ~counts)
}
