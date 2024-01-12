open ReventlessSpec.Adapter
open Reventless.Counter
open AwsSdk.DynamoDb.DocumentClient
open Util.DynamoDbStream_Runtime

let addToCounterTarget = async (table, {counterId, target, targetRef}) => {
  Js.log3(__MODULE__ ++ ".addToCounterTarget:", counterId, target)
  let tableName = table["name"]->Pulumi.Output.get
  switch await update(
    UpdateInput.make(
      ~_TableName=tableName,
      ~_Key={"id": counterId},
      ~_UpdateExpression="ADD #count :inc, #total :inc " ++
      ("SET #targets = list_append(if_not_exists(#targets, :empty), :targetSingle), " ++
      "    #targetRefs = list_append(if_not_exists(#targetRefs, :empty), :targetRefSingle)"),
      ~_ExpressionAttributeNames=[
        ("#count", countFieldName),
        ("#total", "total"),
        ("#targets", "targets"),
        ("#targetRefs", "targetRefs"),
      ]->Js.Dict.fromArray,
      ~_ExpressionAttributeValues={
        ":inc": target,
        ":targetSingle": [target],
        ":targetRefSingle": [targetRef],
        ":targetRef": targetRef,
        ":empty": [],
      },
      ~_ReturnValues=#UPDATED_NEW,
      ~_ConditionExpression="NOT contains(#targetRefs, :targetRef)",
      (),
    ),
  ) {
  | (updateOutput: UpdateOutput.t<{"count": int}>) =>
    Js.log2(
      __MODULE__ ++ `.addToCounterTarget: current count for ${counterId}:`,
      updateOutput["_Attributes"]["count"],
    )
  | exception _ =>
    Js.Exn.raiseError(__MODULE__ ++ `.addToCounterTarget Error: Couldn't count on ${tableName}`)
  }
}

@decco
type referencesView = {
  id: string,
  inc: int,
}

let handleStreamEvent = (
  ~referencesStream: resource,
  ~countsStream: resource,
  ~counterHandler: counterHandler,
  streamEvent,
  _,
) => {
  let referencesARN = referencesStream["urn"]->Pulumi.Output.get
  let countsARN = countsStream["urn"]->Pulumi.Output.get

  let records = streamEvent["_Records"]->Belt.Option.getWithDefault([])
  let (dynamoDbRecords, ignoredRecords) =
    records->Belt.Array.partition(record =>
      record["eventSource"] == "aws:dynamodb" &&
        (record["eventSourceARN"] == referencesARN || record["eventSourceARN"] == countsARN)
    )

  ignoredRecords->Belt.Array.forEach(record =>
    Js.log4(
      __MODULE__ ++ ": ignoring record from eventSource:",
      record["eventSource"],
      record["eventSourceARN"],
      record->Js.Json.stringifyAny,
    )
  )

  let (referenceRecords, countRecords) =
    dynamoDbRecords->Belt.Array.partition(record => record["eventSourceARN"] == referencesARN)

  let references = referenceRecords->Belt.Array.keepMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(id, newImage) =>
      let inc = switch newImage->referencesView_decode {
      | Ok({inc}) => inc
      | _ => 1
      }
      Some((id, inc))
    | _ =>
      Js.log2(__MODULE__ ++ " (references): ignoring record:", record->Js.Json.stringifyAny)
      None
    }
  )

  let counts = countRecords->Belt.Array.keepMap(record =>
    switch record->parseDynamoDbStreamRecordState {
    | NewImage(_, newImage)
    | NewAndOldImage(_, newImage, _) =>
      Some(newImage)
    | _ =>
      Js.log2(__MODULE__ ++ " (counts): ignoring record:", record->Js.Json.stringifyAny)
      None
    }
  )

  counterHandler(~references, ~counts)
}
