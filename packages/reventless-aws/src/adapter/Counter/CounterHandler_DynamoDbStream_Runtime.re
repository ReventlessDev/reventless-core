open ReventlessSpec.Adapter;
open Reventless.Counter;
open AwsSdk.DynamoDb.DocumentClient;
open Util.DynamoDbStream_Runtime;

let addToCounterTarget = (table, {counterId, target, targetRef}) => {
  Js.log3(__MODULE__ ++ ".addToCounterTarget:", counterId, target);
  let tableName = table##name->Pulumi.Output.get;
  update(
    UpdateInput.make(
      ~_TableName=tableName,
      ~_Key={"id": counterId},
      ~_UpdateExpression=
        "ADD #fieldName :inc SET #targets=list_append(#targets,:target), #targetRefs=list_append(#targetRefs:targetRef)",
      ~_ExpressionAttributeNames=
        [
          ("#fieldName", countFieldName),
          ("#targets", "targets"),
          ("#targetRefs", "targetRefs"),
        ]
        ->Js.Dict.fromList,
      ~_ExpressionAttributeValues={
        ":inc": target,
        ":target": [|target|],
        ":targetRef": [|targetRef|],
      },
      ~_ReturnValues=`UPDATED_NEW,
      ~_ConditionExpression="NOT contains(#targetRefs, :targetRef)",
      (),
    ),
  )
  |> Js.Promise.then_((updateOutput: UpdateOutput.t({. count: int})) =>
       Js.log2(
         __MODULE__ ++ {j|.addToCounterTarget: current count for $counterId:|j},
         updateOutput##_Attributes##count,
       )
       ->Js.Promise.resolve
     )
  |> Js.Promise.catch(err =>
       Js.Exn.raiseError(
         __MODULE__
         ++ {j|.addToCounterTarget Error: Couldn't count on $tableName: $err|j},
       )
     );
};

let handleStreamEvent =
    (
      ~referencesStream: resource,
      ~countsStream: resource,
      ~counterHandler: counterHandler,
      streamEvent,
      _,
    ) => {
  let referencesARN = referencesStream##urn->Pulumi.Output.get;
  let countsARN = countsStream##urn->Pulumi.Output.get;

  let records = streamEvent##_Records->Belt.Option.getWithDefault([||]);
  let (dynamoDbRecords, ignoredRecords) =
    records->Belt.Array.partition(record =>
      record##eventSource == "aws:dynamodb"
      && (
        record##eventSourceARN == referencesARN
        ||
        record##eventSourceARN == countsARN
      )
    );

  ignoredRecords->Belt.Array.forEach(record =>
    Js.log4(
      __MODULE__ ++ ": ignoring record from eventSource:",
      record##eventSource,
      record##eventSourceARN,
      record,
    )
  );

  let (referenceRecords, countRecords) =
    dynamoDbRecords->Belt.Array.partition(record =>
      record##eventSourceARN == referencesARN
    );

  let references =
    referenceRecords->Belt.Array.keepMap(record =>
      switch (record->parseDynamoDbStreamRecord) {
      | NewImage(id, _) => Some(id)
      | _ =>
        Js.log2(__MODULE__ ++ " (references): ignoring record:", record);
        None;
      }
    );

  let counts =
    countRecords->Belt.Array.keepMap(record =>
      switch (record->parseDynamoDbStreamRecord) {
      | NewImage(_, newImage)
      | NewAndOldImage(_, newImage, _) => Some(newImage)
      | _ =>
        Js.log2(__MODULE__ ++ " (counts): ignoring record:", record);
        None;
      }
    );

  counterHandler(~references, ~counts);
};
