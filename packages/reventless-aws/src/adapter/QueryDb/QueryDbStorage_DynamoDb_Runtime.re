open AwsSdk.DynamoDb.DocumentClient;
open Belt.Result;
open Js.Promise;
open Reventless;

let load = table =>
  (. id) =>
    table##name->Pulumi.Output.get->queryByIdWithTableName(id)
    |> then_(arr =>
         (
           switch (arr) {
           | [||] => []
           | items => items->Belt.List.fromArray
           }
         )
         ->Ok
         ->resolve
       )
    |> catch(err => {
         let tableName = table##name->Pulumi.Output.get;
         Js.log(
           {j|QueryDbStorage_DynamoDb_Runtime: Error: Couldn't load state for $id from $tableName: $err|j},
         );
         Error(QueryDb.NotLoadedFromStorage(err))->resolve;
       });

let calcPurgeTime = ttl => {
  let now_ms = Reventless.Message.now();
  let now_s = now_ms /. 1000.0;
  let now_s_rounded = now_s->int_of_float;

  (now_s_rounded + ttl)->float_of_int;
};
let purgeTimeAttributeName = "reventlessPurgeTime";

let save = (table, ttl) =>
  (. _id, json, saveMode: QueryDb.saveMode) => {
    let tableName = table##name->Pulumi.Output.get;
    let stateStr = json->Js.Json.stringify;
    let json =
      ttl
      ->Belt.Option.flatMap(ttl =>
          json
          ->Js.Json.decodeObject
          ->Belt.Option.mapWithDefault(
              // TODO: extract mapWithSideEffect to Util module
              () => {
                Js.log2(
                  "QueryDbStorage_DynamoDb_Runtime: Error: Couldn't decode JSON",
                  json->Js.Json.stringify,
                );
                None;
              },
              (obj, ()) => {
                obj->Js.Dict.set(
                  purgeTimeAttributeName,
                  ttl->calcPurgeTime->Js.Json.number,
                );
                obj->Js.Json.object_->Some;
              },
              (),
            )
        )
      ->Belt.Option.getWithDefault(json);

    switch (saveMode) {
    | Init =>
      tableName->putIfNotExists(
        table##hashKey->Pulumi.Output.get,
        table##rangeKey->Pulumi.Output.get,
        json,
      )
      |> then_(_ => {
           Js.log(
             {j|QueryDbStorage_DynamoDb_Runtime: saved Init state to $tableName: $stateStr|j},
           );
           Ok()->resolve;
         })
      |> catch(err => {
           let tableName = table##name->Pulumi.Output.get;

           switch (err->AwsSdk.Error.ofPromise##code) {
           | "ConditionalCheckFailedException" =>
             Js.log(
               {j|QueryDbStorage_DynamoDb_Runtime: Error: Stale State in $tableName|j},
             );
             Error(QueryDb.StaleState)->resolve;
           | _ =>
             Js.log(
               {j|QueryDbStorage_DynamoDb_Runtime: Error: Couldn't save Init state to $tableName: $err|j},
             );
             Error(QueryDb.NotSavedToStorage(err))->resolve;
           };
         })
    | Overwrite =>
      tableName->putWithTableName(json)
      |> then_(_ => {
           Js.log(
             {j|QueryDbStorage_DynamoDb_Runtime: saved Overwrite state to $tableName: $stateStr|j},
           );
           Ok()->resolve;
         })
      |> catch(err => {
           Js.log(
             {j|QueryDbStorage_DynamoDb_Runtime: Error: Couldn't save Overwrite state to $tableName: $err|j},
           );
           Error(QueryDb.NotSavedToStorage(err))->resolve;
         })
    };
  };

let saveBatch:
  (~maxRetries: int=?, ~ttl: option(int), PulumiAws.DynamoDb.Table.t) =>
  (. array((string, Js.Json.t))) =>
  Js.Promise.t(Belt.Result.t(unit, QueryDb.storageError)) =
  (~maxRetries=3, ~ttl, table) =>
    (. items: array((string, Js.Json.t))) => {
      let tableName = table##name->Pulumi.Output.get;
      open AwsSdk.DynamoDb.DocumentClient;

      let batchWrite' = itemRequestMap =>
        batchWrite(
          BatchWriteInput.make(
            ~_RequestItems=itemRequestMap,
            ~_ReturnConsumedCapacity=`NONE,
            ~_ReturnItemCollectionMetris=`NONE,
          ),
        );

      let wrapWithCount = (promise, count) =>
        promise->then_(pContent => (pContent, count)->resolve, _);

      let hasUnprocessedItems = writeOutput =>
        writeOutput##_UnprocessedItems->Js.Dict.keys->Belt.Array.size > 0;

      let rec retryIfNecessary:
        Js.Promise.t((BatchWriteItemOutput.t, /*numberOfRetries*/ int)) =>
        Js.Promise.t((BatchWriteItemOutput.t, /*numberOfRetries*/ int)) =
        p => {
          p->then_(
               ((writeOutput, numberOfRetries) as originalPromiseContent) => {
                 let unprocessedItems = writeOutput##_UnprocessedItems;
                 let unprocessedItemsPresent =
                   hasUnprocessedItems(writeOutput);
                 let numberOfRetriesReached = numberOfRetries >= maxRetries;
                 if (unprocessedItemsPresent && !numberOfRetriesReached) {
                   batchWrite'(unprocessedItems)
                   ->wrapWithCount(numberOfRetries + 1)
                   ->retryIfNecessary;
                 } else {
                   resolve(originalPromiseContent);
                 };
               },
               _,
             );
        };

      let writeRequests =
        items->Belt.Array.map(((_id, json)) =>
          json
          ->WriteRequest.PutRequest.make(~_Item=_)
          ->WriteRequest.make(~_PutRequest=_, ())
        );
      let batchWriteItemRequestMap =
        Js.Dict.fromArray([|(tableName, writeRequests)|]);

      batchWrite'(batchWriteItemRequestMap)
      ->wrapWithCount(0)
      ->retryIfNecessary
      // don't catch any rejections to force retry in stream
      ->then_(
          ((batchWriteItemOutput, _numberOfRetries)) => {
            if (hasUnprocessedItems(batchWriteItemOutput)) {
              Js.Exn.raiseError(
                {j|Still unprocessed items present after maxRetries($maxRetries)!|j},
              );
            };
            resolve(Ok());
          },
          _,
        );
    };

let count = table =>
  (. id, counter, inc) => {
    let tableName = table##name->Pulumi.Output.get;
    Js.log(
      {j|AdapterAws.QueryDbDynamoDB.count: $tableName, $id, $counter, $inc|j},
    );
    update(
      UpdateInput.make(
        ~_TableName=tableName,
        ~_Key={"id": id},
        ~_UpdateExpression="ADD #count :inc",
        ~_ExpressionAttributeNames=[("#count", counter)]->Js.Dict.fromList,
        ~_ExpressionAttributeValues={":inc": inc},
        ~_ReturnValues=`UPDATED_NEW,
        (),
      ),
    )
    |> then_((updateOutput: UpdateOutput.t({. count: int})) =>
         Ok(updateOutput##_Attributes##count)->resolve
       )
    |> catch(err => {
         Js.log(
           {j|QueryDbStorage_DynamoDb_Runtime: Error: Couldn't count on $tableName: $err|j},
         );
         Error(QueryDb.NotCountedOnStorage(err))->resolve;
       });
  };

let delete = table =>
  (. id, sort) => {
    let tableName = table##name->Pulumi.Output.get;
    Js.log4(
      "AdapterAws.QueryDbDynamoDB.delete: tableName, id, sort",
      table##name->Pulumi.Output.get,
      id,
      sort,
    );
    tableName->AwsSdk.DynamoDb.DocumentClient.deleteWithTableName(id, sort)
    |> then_(_ => {
         Js.log(
           {j|QueryDbStorage_DynamoDb_Runtime: deleted state for $id from $tableName|j},
         );
         Ok()->resolve;
       })
    |> catch(err => {
         Js.log(
           {j|QueryDbStorage_DynamoDb_Runtime: Error: Couldn't delete state for $id from $tableName: $err|j},
         );
         Error(QueryDb.NotDeletedFromStorage(err))->resolve;
       });
  };
