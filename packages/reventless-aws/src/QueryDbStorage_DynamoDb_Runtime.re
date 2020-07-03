open Belt.Result;
open Js.Promise;
open Reventless;

let load = table =>
  (. id) =>
    table##name
    ->Pulumi.Output.get
    ->AwsSdk.DynamoDb.DocumentClient.queryByIdWithTableName(id)
    |> then_(arr =>
         (
           switch (arr) {
           | [||] => []
           | items => items |> Array.to_list
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

let save = table =>
  (. _id, json, saveMode: QueryDb.saveMode) => {
    let tableName = table##name->Pulumi.Output.get;
    let stateStr = json->Js.Json.stringify;
    switch (saveMode) {
    | Init =>
      tableName->AwsSdk.DynamoDb.DocumentClient.putIfNotExists(
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
      tableName->AwsSdk.DynamoDb.DocumentClient.putWithTableName(json)
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