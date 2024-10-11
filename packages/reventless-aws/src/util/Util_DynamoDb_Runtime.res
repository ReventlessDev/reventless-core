open AwsSdk.DynamoDb.DocumentClient

let service = "DynamoDb"

let put = (table: PulumiAws.DynamoDb.Table.t, item) => {
  {PutCommand.tableName: table["name"]->Pulumi.Output.get, item}->PutCommand.make->PutCommand.send
}

let delete = (table: PulumiAws.DynamoDb.Table.t, id) => {
  deleteWithTableName(~tableName=table["name"]->Pulumi.Output.get, ~id)
}

let queryById = (table: PulumiAws.DynamoDb.Table.t, id) =>
  queryByIdWithTableName(table["name"]->Pulumi.Output.get, id)

let keysFromResource: ReventlessSpec.Adapter.resource => (string, option<string>) = resource =>
  switch resource["info"]->Pulumi.Output.get->Js.String2.split(",") {
  | [] => Js.Exn.raiseError("No id field given for table " ++ resource["name"]->Pulumi.Output.get)
  | [id]
  | [id, ""] => (id, None)
  | parts => (parts[0], Some(parts[1]))
  }

let purgeTimeAttributeName = "reventlessPurgeTime"

let calcPurgeTime = ttl => {
  let now_ms = Reventless.Message.now()
  let now_s = now_ms /. 1000.0
  let now_s_rounded = now_s->int_of_float

  (now_s_rounded + ttl)->float_of_int
}
let insertTtl: (Js.Json.t, option<int>) => Js.Json.t = (json, ttl) =>
  ttl
  ->Belt.Option.flatMap(ttl =>
    (
      json
      ->Js.Json.decodeObject
      ->Belt.Option.mapWithDefault(
        // TODO: extract mapWithSideEffect to Util module
        () => {
          Js.log2(__MODULE__ ++ ".insertTtl: Error: Couldn't decode JSON", json->Js.Json.stringify)
          (None: option<Js.Json.t>)
        },
        (obj, _) => {
          obj->Js.Dict.set(purgeTimeAttributeName, ttl->calcPurgeTime->Js.Json.number)
          obj->Js.Json.object_->Some
        },
      )
    )()
  )
  ->Belt.Option.getWithDefault(json)

let batchWrite = itemRequestMap => {
  {
    requestItems: itemRequestMap,
    returnConsumedCapacity: NONE,
    returnItemCollectionMetrics: NONE,
  }
  ->BatchWriteCommand.make
  ->BatchWriteCommand.send
}

let hasUnprocessedItems = writeOutput =>
  writeOutput.BatchWriteCommand.unprocessedItems->Belt.Option.mapWithDefault(0, items =>
    items->Js.Dict.keys->Belt.Array.size
  ) > 0

let rec retryBatchWriteIfNecessary = async (p, allItems, numberOfRetries, maxRetries): result<
  unit,
  option<Js.Dict.t<array<AwsSdk.DynamoDb.DocumentClient.BatchWriteCommand.writeRequest>>>,
> => {
  let retry = numberOfRetries->Js.Int.toString
  switch await p {
  | writeOutput =>
    if writeOutput->hasUnprocessedItems {
      let unprocessedItems = writeOutput.BatchWriteCommand.unprocessedItems
      let unprocessedItemsCount: string =
        unprocessedItems
        ->Belt.Option.mapWithDefault(0, items => items->Js.Dict.keys->Belt.Array.size)
        ->Js.Int.toString
      Js.log(
        `Util.DynamoDb_Runtime.retryBatchWriteIfNecessary: retry ${retry}: ${unprocessedItemsCount} unprocessed items`,
      )
      if numberOfRetries < maxRetries {
        await unprocessedItems->Belt.Option.mapWithDefault(
          Js.Promise.resolve(Ok()),
          async items => {
            await batchWrite(items)->retryBatchWriteIfNecessary(
              items,
              numberOfRetries + 1,
              maxRetries,
            )
          },
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
      let p = batchWrite(allItems)
      await retryBatchWriteIfNecessary(p, allItems, numberOfRetries + 1, maxRetries)
    } else {
      Error(Some(allItems))
    }
  }
}

let toPutRequest: Js.Json.t => BatchWriteCommand.writeRequest = json => {
  {putRequest: {BatchWriteCommand.item: json}}
}

let toDeleteRequest: Js.Dict.t<Js.Json.t> => BatchWriteCommand.writeRequest = keys => {
  {deleteRequest: {BatchWriteCommand.key: keys}}
}

let toTable = (writeRequests, tableName) => Js.Dict.fromArray([(tableName, writeRequests)])

let batchWriteWithRetries = (batchWriteItemRequestMap, maxRetries) =>
  batchWrite(batchWriteItemRequestMap)->retryBatchWriteIfNecessary(
    batchWriteItemRequestMap,
    0,
    maxRetries,
  )

let findResource = resources => resources->Reventless.Util.AdapterRuntime.findResource(service)
