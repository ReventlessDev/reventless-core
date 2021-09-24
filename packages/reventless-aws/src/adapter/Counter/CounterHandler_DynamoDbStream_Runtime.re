open ReventlessSpec.Adapter;
open ReventlessSpec.Counter;
open AwsSdk.DynamoDb.DocumentClient;
open Util.DynamoDbStream_Runtime;

let setCounterTarget = (table, {counterId, target}) => {
  Js.log(__MODULE__ ++ ".setCounterTarget:");
  let tableName = table##name->Pulumi.Output.get;
  update(
    UpdateInput.make(
      ~_TableName=tableName,
      ~_Key={"id": counterId},
      ~_UpdateExpression="ADD #fieldName :inc, SET #target :target",
      ~_ExpressionAttributeNames=
        [
          ("#fieldName", Reventless.Counter.countFieldName),
          ("#target", "target"),
        ]
        ->Js.Dict.fromList,
      ~_ExpressionAttributeValues={":inc": target, ":target": target},
      ~_ReturnValues=`UPDATED_NEW,
      ~_ConditionExpression="attribute_not_exists(target)",
      (),
    ),
  )
  |> Js.Promise.then_((updateOutput: UpdateOutput.t({. count: int})) =>
       Js.log2(
         __MODULE__ ++ {j|.setCounterTarget: current count for $counterId:|j},
         updateOutput##_Attributes##count,
       )
       ->Js.Promise.resolve
     )
  |> Js.Promise.catch(err =>
       Js.Exn.raiseError(
         __MODULE__
         ++ {j|.setCounterTarget Error: Couldn't count on $tableName: $err|j},
       )
     );
};

let handleStreamEvent =
    (
      ~referencesDb: resource,
      ~countsDb: resource,
      ~counterHandler: Reventless.Counter.counterHandler,
      streamEvent,
      _,
    ) => {
  let referencesARN = referencesDb##urn->Pulumi.Output.get;
  let countsARN = countsDb##urn->Pulumi.Output.get;

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
