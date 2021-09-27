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
           __MODULE__
           ++ {j|.load: Error: Couldn't load state for $id from $tableName: $err|j},
         );
         Error(
           QueryDb.NotLoadedFromStorage(err->AwsSdk.Error.ofPromise##message),
         )
         ->resolve;
       });

let calcPurgeTime = ttl => {
  let now_ms = Reventless.Message.now();
  let now_s = now_ms /. 1000.0;
  let now_s_rounded = now_s->int_of_float;

  (now_s_rounded + ttl)->float_of_int;
};
let purgeTimeAttributeName = "reventlessPurgeTime";

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

let save = table =>
  (. _id, json, saveMode: QueryDb.saveMode, ttl) => {
    let tableName = table##name->Pulumi.Output.get;
    let stateStr = json->Js.Json.stringify;
    let json = json->insertTtl(ttl);

    switch (saveMode) {
    | Init =>
      tableName->putIfNotExists(
        table##hashKey->Pulumi.Output.get,
        table##rangeKey->Pulumi.Output.get,
        json,
      )
      |> then_(_ => {
           Js.log(
             __MODULE__
             ++ {j|.save: saved Init state to $tableName: $stateStr|j},
           );
           Ok()->resolve;
         })
      |> catch(err => {
           let tableName = table##name->Pulumi.Output.get;

           switch (err->AwsSdk.Error.ofPromise##code) {
           | "ConditionalCheckFailedException" =>
             Js.log(
               __MODULE__ ++ {j|.save: Error: Stale State in $tableName|j},
             );
             Error(QueryDb.StaleState)->resolve;
           | _ =>
             Js.log(
               __MODULE__
               ++ {j|.save: Error: Couldn't save Init state to $tableName: $err|j},
             );
             Error(
               QueryDb.NotSavedToStorage(
                 err->AwsSdk.Error.ofPromise##message,
               ),
             )
             ->resolve;
           };
         })
    | Overwrite =>
      tableName->putWithTableName(json)
      |> then_(_ => {
           Js.log(
             __MODULE__
             ++ {j|.save: saved Overwrite state to $tableName: $stateStr|j},
           );
           Ok()->resolve;
         })
      |> catch(err => {
           Js.log(
             __MODULE__
             ++ {j|.save: Error: Couldn't save Overwrite state to $tableName: $err|j},
           );
           Error(
             QueryDb.NotSavedToStorage(err->AwsSdk.Error.ofPromise##message),
           )
           ->resolve;
         })
    };
  };

let saveBatch:
  (~maxRetries: int=?, PulumiAws.DynamoDb.Table.t) =>
  (. array((string, Js.Json.t, option(int)))) =>
  Js.Promise.t(Belt.Result.t(unit, QueryDb.storageError)) =
  (~maxRetries=3, table) =>
    (. items) => {
      let tableName = table##name->Pulumi.Output.get;
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
        items->Belt.Array.map(((_id, json, ttl)) =>
          json
          ->insertTtl(ttl)
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
  (. id, fieldName, inc) => {
    let tableName = table##name->Pulumi.Output.get;
    Js.log(__MODULE__ ++ {j|.count: $tableName, $id, $fieldName, $inc|j});
    update(
      UpdateInput.make(
        ~_TableName=tableName,
        ~_Key={"id": id},
        ~_UpdateExpression="ADD #fieldName :inc",
        ~_ExpressionAttributeNames=
          [("#fieldName", fieldName)]->Js.Dict.fromList,
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
           __MODULE__
           ++ {j|.count: Error: Couldn't count on $tableName: $err|j},
         );
         Error(
           QueryDb.NotCountedOnStorage(err->AwsSdk.Error.ofPromise##message),
         )
         ->resolve;
       });
  };

let delete = table =>
  (. id, sort) => {
    let tableName = table##name->Pulumi.Output.get;
    Js.log4(
      __MODULE__ ++ ".delete: tableName, id, sort",
      table##name->Pulumi.Output.get,
      id,
      sort,
    );
    tableName->AwsSdk.DynamoDb.DocumentClient.deleteWithTableName(id, sort)
    |> then_(_ => {
         Js.log(
           __MODULE__ ++ {j|.delete: deleted state for $id from $tableName|j},
         );
         Ok()->resolve;
       })
    |> catch(err => {
         Js.log(
           __MODULE__
           ++ {j|.delete: Error: Couldn't delete state for $id from $tableName: $err|j},
         );
         Error(
           QueryDb.NotDeletedFromStorage(
             err->AwsSdk.Error.ofPromise##message,
           ),
         )
         ->resolve;
       });
  };
