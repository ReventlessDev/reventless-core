let mode = `production; // opposed to `debug
open PulumiAws.Lambda;
open Reventless;
open ReventlessSpec.Adapter;

type outputs = {
  .
  "lambda": CallbackFunction.t,
  "tablesToClean": Pulumi.Output.t(array(string)),
};

type dataCleaner;
type t = Component.t(dataCleaner, outputs);

type tableConfig = {
  .
  "name": string,
  "id": string,
  "sort": option(string),
};
type event = {. "tables": Js.nullable(array(tableConfig))};

let handeDeleteResult = result => {
  if (mode == `debug) {
    Js.log("Handle delete result");
  };
  Belt.Result.(
    switch (result) {
    | Error(err) =>
      Js.log2("Couldn't delete item:", err);
      Error("Couldn't delete item.");
    | Ok(_x) => Ok()
    }
  );
};

let deleteAllItems =
    (tableConfig: tableConfig, items: array(Js.Dict.t(string))): unit => {
  items->Belt.Array.map((item: Js.Dict.t(string)) => {
    let id = item->Js.Dict.get(tableConfig##id);
    let sort =
      tableConfig##sort
      ->Belt.Option.flatMap(sortField => item->Js.Dict.get(sortField));
    switch (id, sort) {
    | (Some(id), Some(sort)) =>
      AwsSdk.DynamoDb.DocumentClient.deleteByIdSort(
        ~tableName=tableConfig##name,
        ~id,
        ~sortField=tableConfig##sort->Belt.Option.getExn,
        ~sortKey=sort,
      )
      |> Promise.handlePromise(handeDeleteResult)
    | (Some(id), None) =>
      AwsSdk.DynamoDb.DocumentClient.deleteById(
        ~tableName=tableConfig##name,
        ~id,
      )
      |> Promise.handlePromise(handeDeleteResult)
    | _ => Promise.resolved(Belt.Result.Error("No valid Config found!"))
    };
  })
  |> Promise.all_inArray
  |> Promise.map(result =>
       result->Belt.Array.reduce(0, (state, item) =>
         switch (item) {
         | Belt.Result.Ok(_) => state + 1
         | Belt.Result.Error(_) => state
         }
       )
       |> Js.log3(
            "Deleted",
            _,
            "of "
            ++ result->Belt.Array.length->string_of_int
            ++ " items in table "
            ++
            tableConfig##name,
          )
     )
  |> ignore;
};

let handleScanResult =
    (
      tableConfig: tableConfig,
      scanResult:
        Belt.Result.t(
          AwsSdk.DynamoDb.DocumentClient.QueryOutput.t(Js.Dict.t(string)),
          'a,
        ),
    )
    : Belt.Result.t(int, 'a) => {
  if (mode == `debug) {
    Js.log("Clean table " ++ tableConfig##name);
  };
  switch (scanResult) {
  | Belt.Result.Ok(scanResult) =>
    if (mode == `debug) {
      Js.log2("Items in scan-result:", scanResult##_Items->Belt.Array.length);
    };
    scanResult##_Items |> deleteAllItems(tableConfig);
    Belt.Result.Ok(-1);
  | Belt.Result.Error(error) =>
    if (mode == `debug) {
      Js.log2("Couldn't scan table " ++ tableConfig##name ++ ":", error);
    };
    Belt.Result.Error(error);
  };
};

let scanTableAndClean =
    (tableConfig: tableConfig)
    : Promise.unrejectable(Belt.Result.t(string, string)) => {
  if (mode == `debug) {
    Js.log("Scan " ++ tableConfig##name);
  };

  let idKey = tableConfig##id;
  let (projectionExpression, expressionAttributeNames) =
    switch (tableConfig##sort) {
    | Some(sortKey) => (
        "#" ++ idKey ++ ",#" ++ sortKey,
        [("#" ++ idKey, idKey), ("#" ++ sortKey, sortKey)]
        |> Js.Dict.fromList,
      )
    | None => ("#" ++ idKey, [("#" ++ idKey, idKey)] |> Js.Dict.fromList)
    };

  AwsSdk.DynamoDb.DocumentClient.scan(
    ~params=
      AwsSdk.DynamoDb.DocumentClient.ScanInput.make(
        ~_TableName=tableConfig##name,
        ~_ProjectionExpression=projectionExpression,
        ~_ExpressionAttributeNames=expressionAttributeNames,
        (),
      ),
  )
  |> Promise.handlePromise(handleScanResult(tableConfig))
  /*|> Promise.map(_res => tableConfig##name);*/
  |> Promise.map(
       fun
       | Belt.Result.Ok(deletedItemsCount) =>
         Belt.Result.Ok(
           tableConfig##name
           ++ " ["
           ++ string_of_int(deletedItemsCount)
           ++ "]",
         )
       | Belt.Result.Error(_err) =>
         Belt.Result.Error(tableConfig##name ++ " [ERROR]"),
     );
};

let toTableConfig: resource => tableConfig =
  resource => {
    let name = resource##name->Pulumi.Output.get;
    let (id, sort) = resource->Util_DynamoDb_Runtime.keysFromResource;

    {"name": name, "id": id, "sort": sort};
  };

let cleanerFn: array(resource) => eventHandler(event, string) =
  (tablesToClean, _event, _context) => {
    tablesToClean
    ->Belt.Array.map(toTableConfig)
    ->(
        fun
        | tableConfigs when tableConfigs->Belt.Array.length == 0 =>
          Promise.resolved("No tables to clean.")
        | tableConfigs => {
            tableConfigs->Belt.Array.map(scanTableAndClean)
            |> Promise.all_inArray
            |> Promise.map(arr =>
                 "Cleaned tables "
                 ++ arr->Belt.Array.reduce("", (state, item) =>
                      state
                      ++ " | "
                      ++ (
                        item
                        |> (
                          fun
                          | Belt.Result.Ok(successMsg) => successMsg
                          | Belt.Result.Error(errorMsg) => errorMsg
                        )
                      )
                    )
               );
          }
      )
    |> Promise.toJs;
  };

let stackName = prefix =>
  (
    switch (prefix) {
    | Some(prefix) => (prefix |> Js.String.replace("_", "-")) ++ "-"
    | None => ""
    }
  )
  ++ Pulumi.Pulumi.getProjectName()
  ++ "-"
  ++ Pulumi.Pulumi.getStackName();

type keep = string => bool;

type constructed;
type construct = (Component.t(dataCleaner, outputs), string) => constructed;

[@bs.obj]
external makeOutputs:
  (
    ~lambda: CallbackFunction.t,
    ~tablesToClean: Pulumi.Output.t(array(string))
  ) =>
  outputs =
  "";

[@bs.module "../../../reventless/src/components/Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  Component.t(dataCleaner, outputs) =
  "default";

[@bs.send]
external registerOutputs:
  (Component.t(dataCleaner, outputs), outputs) => constructed =
  "registerOutputs";
[@bs.send]
external setOutputs: (Component.t(dataCleaner, outputs), outputs) => unit =
  "setOutputs";
let setOutputs = (outputs, self) => {
  self->setOutputs(outputs);
  self->registerOutputs(outputs);
};

let construct = (~keep: keep, self, name) => {
  let opts =
    Pulumi.CustomResourceOptions.make(
      ~parent=self->Component.toPulumiResource,
      (),
    );

  let tablesToClean =
    [|
      Util.EventLog.Deploytime.filterEventLogStorages(keep),
      Util.QueryDb.Deploytime.filterQueryDbStorages(keep),
    |]
    ->Belt.Array.concatMany;

  let lambda =
    CallbackFunction.make(
      ~name,
      ~args=
        CallbackFunction.Args.make(
          ~callback=cleanerFn(tablesToClean),
          ~memorySize=1024->Pulumi.Input.wrap,
          (),
        ),
      ~opts,
      (),
    );

  let tablesToClean =
    tablesToClean
    ->Belt.Array.map(resource => resource##name)
    ->Pulumi.Output.all;

  makeOutputs(~lambda, ~tablesToClean)->setOutputs(self);
};

let make = (~keep: keep, ~prefix: option(string)=?, ~opts=?, _: unit) => {
  make(
    ~componentType="DataCleaner",
    ~name="-" ++ stackName(prefix),
    ~construct=construct(~keep),
    ~opts,
  );
};
