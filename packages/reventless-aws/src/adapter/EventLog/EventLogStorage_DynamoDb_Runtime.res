open Util_DynamoDb_Runtime

let append = table => async (. _sequenceNr, _id, jsons) => {
  let result =
    jsons
    ->Belt.Array.map(toPutRequest)
    ->toTable(table["name"]->Pulumi.Output.get)
    ->batchWriteWithRetries(3)
  switch await result {
  | _ => Belt.Result.Ok()
  | exception _ => Belt.Result.Error("AwsSdk.DynamoDb.DocumentClient.putMany failed !") // TODO: error message
  }
}

let replay = table => (. id) =>
  table["name"]->Pulumi.Output.get->AwsSdk.DynamoDb.DocumentClient.queryByIdWithTableName(id)
