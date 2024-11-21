open Util_DynamoDb_Runtime

let append = table => async (. _sequenceNr, _id, jsons) => {
  let result =
    jsons
    ->Belt.Array.map(toPutRequest)
    ->toTable(table["name"]->Pulumi.Output.get)
    ->batchWriteWithRetries
  switch await result {
  | Ok() => Ok()
  | Error(unprocessedItems) =>
    Js.Console.log2("Error: unprocessed items:", unprocessedItems)
    Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries resulted in unprocessed items !")
  | exception _ => Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries failed !") // TODO: error message
  }
}

let replay = table => (. id) =>
  AwsSdk.DynamoDb.DocumentClient.queryById(table["name"]->Pulumi.Output.get, id)
