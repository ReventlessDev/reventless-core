/* let mode = #production // opposed to `debug
open PulumiAws.Lambda
open ReventlessInfra.Adapter

type tableConfig = {name: string, id: string, sort: option<string>}
type event = {tables: nullable<array<tableConfig>>}

let promiseToResult: promise<'a> => promise<result<'a, 'b>> = async p =>
  switch await p {
  | res => Ok(res)
  | exception err => Error(err)
  }

let handleDeleteResult = result => {
  if mode == #debug {
    Console.log("Handle delete result")
  }
  // Belt.Result removed — Ok/Error are global in RescriptCore
  switch result {
  | Error(err) =>
    Console.log2("Couldn't delete item:", err)
    Error("Couldn't delete item.")
  | Ok(_x) => Ok()
  }
}

let deleteAllItems = async (items: array<dict<string>>, tableConfig: tableConfig): unit =>
  switch await items
  ->Array.map(async (item: dict<string>) => {
    let id = item->Dict.get(tableConfig.id)
    let sort = tableConfig.sort->Option.flatMap(sortField => item->Dict.get(sortField))
    switch (id, sort) {
    | (Some(id), Some(sort)) =>
      switch await AwsSdk.DynamoDb.DocumentClient.deleteByIdSort(
        ~tableName=tableConfig.name,
        ~id,
        ~sortField=tableConfig.sort->Option.getExn,
        ~sortKey=sort,
      )->promiseToResult {
      | res => res->handleDeleteResult
      }
    | (Some(id), None) =>
      switch await AwsSdk.DynamoDb.DocumentClient.deleteById(
        ~tableName=tableConfig.name,
        ~id,
      )->promiseToResult {
      | res => res->handleDeleteResult
      }
    //Promise.handlePromise(handeDeleteResult)
    | _ => Error("No valid Config found!")
    }
  })
  ->Promise.all {
  | result =>
    result
    ->Array.reduce(0, (state, item) =>
      switch item {
      | Ok(_) => state + 1
      | Error(_) => state
      }
    )
    ->Console.log3(
      "Deleted",
      _,
      "of " ++
      (result->Array.length->Int.toString ++
      (" items in table " ++ tableConfig.name)),
    )
  }

let handleScanResult = async (
  tableConfig: tableConfig,
  scanResult: result<AwsSdk.DynamoDb.DocumentClient.QueryCommand.output, 'a>,
): result<int, 'a> => {
  if mode == #debug {
    Console.log("Clean table " ++ tableConfig.name)
  }
  switch scanResult {
  | Ok(scanResult) =>
    if mode == #debug {
      Console.log2("Items in scan-result:", scanResult.items->Array.length)
    }
    let _ = await scanResult.items->deleteAllItems(tableConfig)
    Ok(-1)
  | Error(error) =>
    if mode == #debug {
      Console.log2("Couldn't scan table " ++ (tableConfig.name ++ ":"), error)
    }
    Error(error)
  }
}

let scanTableAndClean = async (tableConfig: tableConfig): promise<
  result<string, string>,
> => {
  if mode == #debug {
    Console.log("Scan " ++ tableConfig.name)
  }

  let idKey = tableConfig.id
  let (projectionExpression, expressionAttributeNames) = switch tableConfig.sort {
  | Some(sortKey) => (
      "#" ++ (idKey ++ (",#" ++ sortKey)),
      [("#" ++ idKey, idKey), ("#" ++ sortKey, sortKey)]->Dict.fromArray,
    )
  | None => ("#" ++ idKey, [("#" ++ idKey, idKey)]->Dict.fromArray)
  }

  switch await AwsSdk.DynamoDb.DocumentClient.scan(
    ~params=AwsSdk.DynamoDb.DocumentClient.ScanInput.make(
      ~_TableName=tableConfig.name,
      ~_ProjectionExpression=projectionExpression,
      ~_ExpressionAttributeNames=expressionAttributeNames,
      (),
    ),
  )->promiseToResult {
  | res => {
      let scanResult = await handleScanResult(tableConfig, res)
      let deletedItemsCount = switch scanResult {
      | Ok(deletedItemsCount) =>
        Ok(tableConfig.name ++ (" [" ++ (Int.toString(deletedItemsCount) ++ "]")))
      | Error(_err) => Error(tableConfig.name ++ " [ERROR]")
      }
      deletedItemsCount->Promise.resolve
    }
  }
}

let toTableConfig: resource => tableConfig = resource => {
  let name = resource.name->Pulumi.Output.get
  let (id, sort) = resource->Util_DynamoDb_Runtime.keysFromResource

  {name, id, sort}
}

let cleanerFn = async (tablesToClean, _event, _context) =>
  switch tablesToClean->Array.map(toTableConfig) {
  | tableConfigs if tableConfigs->Array.length == 0 => "No tables to clean."
  | tableConfigs =>
    switch await tableConfigs->Array.map(scanTableAndClean)->Promise.all {
    | results => {
        let summary = results->Array.reduce(Promise.resolve(""), async (state, result) =>
          (await state) ++
          (" | " ++
          switch await result {
          | Ok(successMsg) => successMsg
          | Error(errorMsg) => errorMsg
          })
        )
        "Cleaned tables " ++ (await summary)
      }
    }
  }

let stackName = prefix =>
  switch prefix {
  | Some(prefix) => prefix->String.replace("_", "-") ++ "-"
  | None => ""
  } ++
  (Pulumi.Pulumi.getProjectName() ++
  ("-" ++ Pulumi.Pulumi.getStackName()))

let make = (~prefix: option<string>, ~tablesToClean: array<resource>) => {
  open CallbackFunction
  make(
    ~name="DataCleaner-" ++ stackName(prefix),
    ~args=Args.make(~callback=cleanerFn(tablesToClean, ...), ~memorySize=1024->Pulumi.Input.make),
  )
}
*/
