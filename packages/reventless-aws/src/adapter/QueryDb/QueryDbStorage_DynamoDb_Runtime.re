open AwsSdk.DynamoDb.DocumentClient;
open Util_DynamoDb_Runtime;
open Belt.Result;
open Js.Promise;
open Reventless.QueryDb;
open Reventless.Util.Error;

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
         Error(NotLoadedFromStorage(err->ofPromise##message))->resolve;
       });

let save = table =>
  (. _id, json, saveMode: saveMode, ttl) => {
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

           switch (err->ofPromise##code) {
           | "ConditionalCheckFailedException" =>
             Js.log(
               __MODULE__ ++ {j|.save: Error: Stale State in $tableName|j},
             );
             Error(StaleState)->resolve;
           | _ =>
             Js.log(
               __MODULE__
               ++ {j|.save: Error: Couldn't save Init state to $tableName: $err|j},
             );
             Error(NotSavedToStorage(err->ofPromise##message))->resolve;
           };
         })
    | Any
    | Overwrite =>
      tableName->putWithTableName(json)
      |> then_(_ => {
           Js.log(
             __MODULE__ ++ {j|.save: saved state to $tableName: $stateStr|j},
           );
           Ok()->resolve;
         })
      |> catch(err => {
           Js.log(
             __MODULE__
             ++ {j|.save: Error: Couldn't save state to $tableName: $err|j},
           );
           Error(NotSavedToStorage(err->ofPromise##message))->resolve;
         })
    };
  };

let saveBatch:
  (~maxRetries: int=?, PulumiAws.DynamoDb.Table.t) =>
  (. array((string, Js.Json.t, option(int)))) =>
  Js.Promise.t(Belt.Result.t(unit, storageError)) =
  (~maxRetries=3, table) =>
    (. items) => {
      items
      ->Belt.Array.map(((_id, json, ttl)) =>
          json->insertTtl(ttl)->toPutRequest
        )
      ->toTable(table##name->Pulumi.Output.get)
      ->batchWriteWithRetries(maxRetries)
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
         Error(NotCountedOnStorage(err->ofPromise##message))->resolve;
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
         Error(NotDeletedFromStorage(err->ofPromise##message))->resolve;
       });
  };
