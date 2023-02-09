open AwsSdk.DynamoDb.DocumentClient;

let service = "DynamoDb";

let put = (table: PulumiAws.DynamoDb.Table.t, item) =>
  putWithTableName(table##name->Pulumi.Output.get, item);

let delete = (table: PulumiAws.DynamoDb.Table.t, id) =>
  deleteWithTableName(table##name->Pulumi.Output.get, id, None);

let queryById = (table: PulumiAws.DynamoDb.Table.t, id) =>
  queryByIdWithTableName(table##name->Pulumi.Output.get, id);

let keysFromResource = (resource: ReventlessSpec.Adapter.resource) =>
  switch (resource##info |> Pulumi.Output.get |> Js.String.split(",")) {
  | [||] =>
    Js.Exn.raiseError(
      "No id field given for table " ++ resource##name->Pulumi.Output.get,
    )
  | [|id|]
  | [|id, ""|] => (id, None)
  | parts => (parts[0], Some(parts[1]))
  };

let purgeTimeAttributeName = "reventlessPurgeTime";

let calcPurgeTime = ttl => {
  let now_ms = Reventless.Message.now();
  let now_s = now_ms /. 1000.0;
  let now_s_rounded = now_s->int_of_float;

  (now_s_rounded + ttl)->float_of_int;
};
let insertTtl = (json, ttl) =>
  ttl
  ->Belt.Option.flatMap(ttl =>
      (
        json
        ->Js.Json.decodeObject
        ->Belt.Option.mapWithDefault(
            // TODO: extract mapWithSideEffect to Util module
            () => {
              Js.log2(
                __MODULE__ ++ ".insertTtl: Error: Couldn't decode JSON",
                json->Js.Json.stringify,
              );
              None;
            },
            (obj, _) => {
              obj->Js.Dict.set(
                purgeTimeAttributeName,
                ttl->calcPurgeTime->Js.Json.number,
              );
              obj->Js.Json.object_->Some;
            },
          )
      )()
    )
  ->Belt.Option.getWithDefault(json);

/** batchWrite: max. batch size is 25 */
let batchWrite = params =>
  make()
  ->AwsSdk.DynamoDb.DocumentClient.batchWrite(~params)
  ->AwsSdk.Request.promise;

let batchWrite' = itemRequestMap =>
  batchWrite(
    BatchWriteInput.make(
      ~_RequestItems=itemRequestMap,
      ~_ReturnConsumedCapacity=`NONE,
      ~_ReturnItemCollectionMetris=`NONE,
    ),
  );

let wrapWithCount = (promise, count) =>
  promise->Js.Promise.then_(
             pContent => (pContent, count)->Js.Promise.resolve,
             _,
           );

let hasUnprocessedItems = writeOutput =>
  writeOutput##_UnprocessedItems->Js.Dict.keys->Belt.Array.size > 0;

let rec retryIfNecessary:
  (Js.Promise.t((BatchWriteItemOutput.t, /*numberOfRetries*/ int)), int) =>
  Js.Promise.t((BatchWriteItemOutput.t, /*numberOfRetries*/ int)) =
  (p, maxRetries) => {
    p->Js.Promise.then_(
         ((writeOutput, numberOfRetries) as originalPromiseContent) => {
           let unprocessedItems = writeOutput##_UnprocessedItems;
           let unprocessedItemsPresent = hasUnprocessedItems(writeOutput);
           let numberOfRetriesReached = numberOfRetries >= maxRetries;
           if (unprocessedItemsPresent && !numberOfRetriesReached) {
             batchWrite'(unprocessedItems)
             ->wrapWithCount(numberOfRetries + 1)
             ->retryIfNecessary(maxRetries);
           } else {
             originalPromiseContent->Js.Promise.resolve;
           };
         },
         _,
       );
  };

let toPutRequest = json =>
  json
  ->WriteRequest.PutRequest.make(~_Item=_)
  ->WriteRequest.make(~_PutRequest=_, ());

let toTable = (writeRequests, tableName) =>
  Js.Dict.fromArray([|(tableName, writeRequests)|]);

let batchWriteWithRetries = (batchWriteItemRequestMap, maxRetries) =>
  batchWrite'(batchWriteItemRequestMap)
  ->wrapWithCount(0)
  ->retryIfNecessary(maxRetries);

let findResource = resources =>
  resources->Reventless.Util.AdapterRuntime.findResource(service);
