open Util_DynamoDb_Runtime;

let append = table =>
  (. _sequenceNr, _id, jsons) =>
    jsons
    ->Belt.Array.map(toPutRequest)
    ->toTable(table##name->Pulumi.Output.get)
    ->batchWriteWithRetries(3)
    |> Js.Promise.then_(_ => Belt.Result.Ok()->Js.Promise.resolve)
    |> Js.Promise.catch(_ =>
         Belt.Result.Error("AwsSdk.DynamoDb.DocumentClient.putMany failed !")
         ->Js.Promise.resolve
       );

let replay = table =>
  (. id) =>
    table##name
    ->Pulumi.Output.get
    ->AwsSdk.DynamoDb.DocumentClient.queryByIdWithTableName(id);
