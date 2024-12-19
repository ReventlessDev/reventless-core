open Util_DynamoDb_Runtime

let append = (table: PulumiAws.DynamoDb.Table.t) =>
  async (_sequenceNr, _id, jsons) => {
    let result =
      jsons
      ->Belt.Array.map(toPutRequest)
      ->toTable(table.name->Pulumi.Output.get)
      ->batchWriteWithRetries
    switch await result {
    | Ok() => Ok()
    | Error(unprocessedItems) =>
      Reventless.Logger.error("Error: unprocessed items:", unprocessedItems)
      Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries resulted in unprocessed items !")
    | exception _ => Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries failed !") // TODO: error message
    }
  }

let rec tryReplay = async (~retry=0, tableName, id) =>
  switch await AwsSdk.DynamoDb.DocumentClient.queryById(tableName, id) {
  | exception Js.Exn.Error(e) =>
    Reventless.Logger.warn(
      ~loc=__LOC__,
      `Couldn't replay events for id ${id}, retry:${retry->Js.Int.toString}`,
      e,
    )
    let timeout = 100 * retry + Js.Math.random_int(0, 100)
    await Reventless.Util.Promise.finishTimeout(timeout)
    await tableName->tryReplay(~retry=retry + 1, id)
  | history => history
  }

let replay = (table: PulumiAws.DynamoDb.Table.t) => {
  async id => await table.name->Pulumi.Output.get->tryReplay(id)
}
