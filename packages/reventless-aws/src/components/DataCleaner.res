let mode = #production // opposed to `debug
open PulumiAws.Lambda
open ReventlessSpec.Adapter

type tableConfig = {"name": string, "id": string, "sort": option<string>}
type event = {"tables": Js.nullable<array<tableConfig>>}

let promiseToResult: Js.Promise.t<'a> => Js.Promise.t<Belt.Result.t<'a, 'b>> = p =>
  p
  ->Js.Promise2.then(res => Belt.Result.Ok(res)->Js.Promise.resolve)
  ->Js.Promise2.catch(err => Belt.Result.Error(err)->Js.Promise.resolve)

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

let deleteAllItems = (items: array<Js.Dict.t<string>>, tableConfig: tableConfig): unit =>
  items
  ->Belt.Array.map((item: Js.Dict.t<string>) => {
    let id = item->Js.Dict.get(tableConfig["id"])
    let sort = tableConfig["sort"]->Belt.Option.flatMap(sortField => item->Js.Dict.get(sortField))
    switch (id, sort) {
    | (Some(id), Some(sort)) =>
      AwsSdk.DynamoDb.DocumentClient.deleteByIdSort(
        ~tableName=tableConfig["name"],
        ~id,
        ~sortField=tableConfig["sort"]->Belt.Option.getExn,
        ~sortKey=sort,
      )
      ->promiseToResult
      ->Js.Promise2.then(res => res->handleDeleteResult->Js.Promise.resolve)
    | (Some(id), None) =>
      AwsSdk.DynamoDb.DocumentClient.deleteById(~tableName=tableConfig["name"], ~id)
      ->promiseToResult
      ->Js.Promise2.then(res => res->handleDeleteResult->Js.Promise.resolve)
    //Promise.handlePromise(handeDeleteResult)
    | _ =>
      Js.Promise.make((~resolve, ~reject as _) =>
        resolve(. Belt.Result.Error("No valid Config found!"))
      )
    }
  })
  ->Js.Promise.all
  ->Js.Promise2.then(result =>
    result
    ->Belt.Array.reduce(0, (state, item) =>
      switch item {
      | Belt.Result.Ok(_) => state + 1
      | Belt.Result.Error(_) => state
      }
    )
    ->Js.log3(
      "Deleted",
      _,
      "of " ++
      (result->Belt.Array.length->string_of_int ++
      (" items in table " ++ tableConfig["name"])),
    )
    ->Js.Promise.resolve
  )
  ->ignore

let handleScanResult = (
  tableConfig: tableConfig,
  scanResult: Belt.Result.t<AwsSdk.DynamoDb.DocumentClient.QueryOutput.t<Js.Dict.t<string>>, 'a>,
): Belt.Result.t<int, 'a> => {
  if mode == #debug {
    Js.log("Clean table " ++ tableConfig["name"])
  }
  switch scanResult {
  | Belt.Result.Ok(scanResult) =>
    if mode == #debug {
      Js.log2("Items in scan-result:", scanResult["_Items"]->Belt.Array.length)
    }
    scanResult["_Items"]->deleteAllItems(tableConfig)
    Belt.Result.Ok(-1)
  | Belt.Result.Error(error) =>
    if mode == #debug {
      Js.log2("Couldn't scan table " ++ (tableConfig["name"] ++ ":"), error)
    }
    Belt.Result.Error(error)
  }
}

let scanTableAndClean = (tableConfig: tableConfig): Js.Promise.t<Belt.Result.t<string, string>> => {
  if mode == #debug {
    Js.log("Scan " ++ tableConfig["name"])
  }

  let idKey = tableConfig["id"]
  let (projectionExpression, expressionAttributeNames) = switch tableConfig["sort"] {
  | Some(sortKey) => (
      "#" ++ (idKey ++ (",#" ++ sortKey)),
      [("#" ++ idKey, idKey), ("#" ++ sortKey, sortKey)]->Js.Dict.fromArray,
    )
  | None => ("#" ++ idKey, [("#" ++ idKey, idKey)]->Js.Dict.fromArray)
  }

  AwsSdk.DynamoDb.DocumentClient.scan(
    ~params=AwsSdk.DynamoDb.DocumentClient.ScanInput.make(
      ~_TableName=tableConfig["name"],
      ~_ProjectionExpression=projectionExpression,
      ~_ExpressionAttributeNames=expressionAttributeNames,
      (),
    ),
  )
  ->promiseToResult
  ->Js.Promise2.then(res => {
    let scanResult = handleScanResult(tableConfig, res)
    let deletedItemsCount = switch scanResult {
    | Belt.Result.Ok(deletedItemsCount) =>
      Belt.Result.Ok(tableConfig["name"] ++ (" [" ++ (string_of_int(deletedItemsCount) ++ "]")))
    | Belt.Result.Error(_err) => Belt.Result.Error(tableConfig["name"] ++ " [ERROR]")
    }
    deletedItemsCount->Js.Promise.resolve
  })
}

let toTableConfig: resource => tableConfig = resource => {
  let name = resource["name"]->Pulumi.Output.get
  let (id, sort) = resource->Util_DynamoDb_Runtime.keysFromResource

  {"name": name, "id": id, "sort": sort}
}

let cleanerFn: array<resource> => eventHandler<event, string> = (tablesToClean, _event, _context) =>
  tablesToClean
  ->Belt.Array.map(toTableConfig)
  ->(
    x =>
      switch x {
      | tableConfigs if tableConfigs->Belt.Array.length == 0 =>
        Js.Promise.make((~resolve, ~reject as _) => resolve(. "No tables to clean."))
      | tableConfigs =>
        tableConfigs
        ->Belt.Array.map(scanTableAndClean)
        ->Js.Promise.all
        ->Js.Promise2.then(arr => {
          let summary = arr->Belt.Array.reduce("", (state, item) =>
            state ++
            (" | " ++
            item->(
              x =>
                switch x {
                | Belt.Result.Ok(successMsg) => successMsg
                | Belt.Result.Error(errorMsg) => errorMsg
                }
            ))
          )
          ("Cleaned tables " ++ summary)->Js.Promise.resolve
        })
      }
  )

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
    ~args=Args.make(~callback=cleanerFn(tablesToClean), ~memorySize=1024->Pulumi.Input.make, ()),
    (),
  )
}
