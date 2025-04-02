/* let mode = #production // opposed to `debug
open PulumiAws.Lambda
open ReventlessSpec.Adapter

type tableConfig = {name: string, id: string, sort: option<string>}
type event = {tables: Js.nullable<array<tableConfig>>}

let promiseToResult: Js.Promise.t<'a> => Js.Promise.t<Belt.Result.t<'a, 'b>> = async p =>
  switch await p {
  | res => Belt.Result.Ok(res)
  | exception err => Belt.Result.Error(err)
  }

let handleDeleteResult = result => {
  if mode == #debug {
    Js.log("Handle delete result")
  }
  open Belt.Result
  switch result {
  | Error(err) =>
    Js.log2("Couldn't delete item:", err)
    Error("Couldn't delete item.")
  | Ok(_x) => Ok()
  }
}

let deleteAllItems = async (items: array<Js.Dict.t<string>>, tableConfig: tableConfig): unit =>
  switch await items
  ->Array.map(async (item: Js.Dict.t<string>) => {
    let id = item->Js.Dict.get(tableConfig.id)
    let sort = tableConfig.sort->Belt.Option.flatMap(sortField => item->Js.Dict.get(sortField))
    switch (id, sort) {
    | (Some(id), Some(sort)) =>
      switch await AwsSdk.DynamoDb.DocumentClient.deleteByIdSort(
        ~tableName=tableConfig.name,
        ~id,
        ~sortField=tableConfig.sort->Belt.Option.getExn,
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
    | _ => Belt.Result.Error("No valid Config found!")
    }
  })
  ->Js.Promise.all {
  | result =>
    result
    ->Array.reduce(0, (state, item) =>
      switch item {
      | Belt.Result.Ok(_) => state + 1
      | Belt.Result.Error(_) => state
      }
    )
    ->Js.log3(
      "Deleted",
      _,
      "of " ++
      (result->Array.length->string_of_int ++
      (" items in table " ++ tableConfig.name)),
    )
  }

let handleScanResult = async (
  tableConfig: tableConfig,
  scanResult: Belt.Result.t<AwsSdk.DynamoDb.DocumentClient.QueryCommand.output, 'a>,
): Belt.Result.t<int, 'a> => {
  if mode == #debug {
    Js.log("Clean table " ++ tableConfig.name)
  }
  switch scanResult {
  | Belt.Result.Ok(scanResult) =>
    if mode == #debug {
      Js.log2("Items in scan-result:", scanResult.items->Array.length)
    }
    let _ = await scanResult.items->deleteAllItems(tableConfig)
    Belt.Result.Ok(-1)
  | Belt.Result.Error(error) =>
    if mode == #debug {
      Js.log2("Couldn't scan table " ++ (tableConfig.name ++ ":"), error)
    }
    Belt.Result.Error(error)
  }
}

let scanTableAndClean = async (tableConfig: tableConfig): Js.Promise.t<
  Belt.Result.t<string, string>,
> => {
  if mode == #debug {
    Js.log("Scan " ++ tableConfig.name)
  }

  let idKey = tableConfig.id
  let (projectionExpression, expressionAttributeNames) = switch tableConfig.sort {
  | Some(sortKey) => (
      "#" ++ (idKey ++ (",#" ++ sortKey)),
      [("#" ++ idKey, idKey), ("#" ++ sortKey, sortKey)]->Js.Dict.fromArray,
    )
  | None => ("#" ++ idKey, [("#" ++ idKey, idKey)]->Js.Dict.fromArray)
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
      | Belt.Result.Ok(deletedItemsCount) =>
        Belt.Result.Ok(tableConfig.name ++ (" [" ++ (string_of_int(deletedItemsCount) ++ "]")))
      | Belt.Result.Error(_err) => Belt.Result.Error(tableConfig.name ++ " [ERROR]")
      }
      deletedItemsCount->Js.Promise.resolve
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
    switch await tableConfigs->Array.map(scanTableAndClean)->Js.Promise.all {
    | results => {
        let summary = results->Array.reduce(Js.Promise.resolve(""), async (state, result) =>
          (await state) ++
          (" | " ++
          switch await result {
          | Belt.Result.Ok(successMsg) => successMsg
          | Belt.Result.Error(errorMsg) => errorMsg
          })
        )
        "Cleaned tables " ++ (await summary)
      }
    }
  }

let stackName = prefix =>
  switch prefix {
  | Some(prefix) => prefix->Js.String2.replace("_", "-") ++ "-"
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
