open AwsSdk.DynamoDb.DocumentClient

let service = "DynamoDb"

let put = (table: PulumiAws.DynamoDb.Table.t, item) =>
  putWithTableName(table.name->Pulumi.Output.get, item)

let delete = (table: PulumiAws.DynamoDb.Table.t, id) =>
  deleteWithTableName(table.name->Pulumi.Output.get, id, None)

let queryById = (table: PulumiAws.DynamoDb.Table.t, id) =>
  queryByIdWithTableName(table.name->Pulumi.Output.get, id)

let keysFromResource = (resource: ReventlessSpec.Adapter.resource) =>
  switch resource.info->Pulumi.Output.get->Js.String2.split(",") {
  | [] => Js.Exn.raiseError("No id field given for table " ++ resource.name->Pulumi.Output.get)
  | [id]
  | [id, ""] => (id, None)
  | parts => (parts->Array.getUnsafe(0), parts[1])
  }

let purgeTimeAttributeName = "reventlessPurgeTime"

let calcPurgeTime = ttl => {
  let now_ms = Reventless.Message.now()
  let now_s = now_ms /. 1000.0
  let now_s_rounded = now_s->int_of_float

  (now_s_rounded + ttl)->float_of_int
}
let insertTtl = (json, ttl) =>
  ttl
  ->Belt.Option.flatMap(ttl =>
    (
      json
      ->Js.Json.decodeObject
      ->Belt.Option.mapWithDefault(
        // TODO: extract mapWithSideEffect to Util module
        () => {
          Js.log2(__MODULE__ ++ ".insertTtl: Error: Couldn't decode JSON", json->Js.Json.stringify)
          None
        },
        obj => {
          obj->Js.Dict.set(purgeTimeAttributeName, ttl->calcPurgeTime->Js.Json.number)
          () => Some(obj->Js.Json.object_)
        },
      )
    )()
  )
  ->Belt.Option.getWithDefault(json)

/** batchWrite: max. batch size is 25 */
let batchWrite = params =>
  make()->AwsSdk.DynamoDb.DocumentClient.batchWrite(~params)->AwsSdk.Request.promise

let batchWrite' = itemRequestMap =>
  batchWrite(
    BatchWriteInput.make(
      ~_RequestItems=itemRequestMap,
      ~_ReturnConsumedCapacity=#NONE,
      ~_ReturnItemCollectionMetris=#NONE,
    ),
  )

let hasUnprocessedItems = writeOutput =>
  writeOutput["_UnprocessedItems"]->Js.Dict.keys->Belt.Array.size > 0

let rec retryBatchWriteIfNecessary = async (p, allItems, numberOfRetries, maxRetries) => {
  let retry = numberOfRetries->Js.Int.toString
  switch await p {
  | writeOutput =>
    if writeOutput->hasUnprocessedItems {
      let unprocessedItems = writeOutput["_UnprocessedItems"]
      let unprocessedItemsCount = unprocessedItems->Js.Dict.keys->Belt.Array.size->Js.Int.toString
      Js.log(
        `Util.DynamoDb_Runtime.retryBatchWriteIfNecessary: retry ${retry}: ${unprocessedItemsCount} unprocessed items`,
      )
      if numberOfRetries < maxRetries {
        await batchWrite'(unprocessedItems)->retryBatchWriteIfNecessary(
          unprocessedItems,
          numberOfRetries + 1,
          maxRetries,
        )
      } else {
        Error(unprocessedItems)
      }
    } else {
      Ok()
    }

  | exception Js.Exn.Error(e) =>
    Js.log2(`Util.DynamoDb_Runtime.retryBatchWriteIfNecessary: retry ${retry}: Error:`, e)
    if numberOfRetries < maxRetries {
      await batchWrite'(allItems)->retryBatchWriteIfNecessary(
        allItems,
        numberOfRetries + 1,
        maxRetries,
      )
    } else {
      Error(allItems)
    }
  }
}

let toPutRequest = json =>
  WriteRequest.make(~_PutRequest=WriteRequest.PutRequest.make(~_Item=json), ())

let toDeleteRequest = keys =>
  WriteRequest.make(~_DeleteRequest=WriteRequest.DeleteRequest.make(~_Key=keys), ())

let toTable = (writeRequests, tableName) => Js.Dict.fromArray([(tableName, writeRequests)])

let batchWriteWithRetries = (batchWriteItemRequestMap, maxRetries) =>
  batchWrite'(batchWriteItemRequestMap)->retryBatchWriteIfNecessary(
    batchWriteItemRequestMap,
    0,
    maxRetries,
  )

let findResource = resources => resources->Reventless.Util.AdapterRuntime.findResource(service)
