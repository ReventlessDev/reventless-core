let getRemoteStorageResources = (pluginName, queryDbName) =>
  switch (
    Util_StackRefs.get(pluginName)
    ->Belt.Option.map(stackRef =>
        stackRef
        ->Pulumi.StackReference.requireOutput("plugin"->Pulumi.Input.wrap)
        ->Pulumi.Output.apply(plugin =>
            plugin##readModels
            ->Belt.Option.flatMap(readModels =>
                readModels->Js.Dict.get(queryDbName)
              )
            ->Belt.Option.map(readModel =>
                readModel##queryDb##resources
                ->Belt.Array.map(Adapter.unwrappedOutputToResource)
              )
            ->Belt.Option.getWithDefault([||])
          )
      )
  ) {
  | Some(resources) =>
    Js.log4(
      "Util_QueryDb.getRemoteStorageResources: pluginName:",
      pluginName,
      ", queryDbName:",
      queryDbName,
    );
    Js.log(
      "Util_QueryDb.getRemoteStorageResources: resources: ----------------",
    );
    let _ =
      resources->Pulumi.Output.apply(resources =>
        resources->Belt.Array.forEach(resource => Js.log(resource))
      );
    resources;
  | None =>
    Js.log(
      "Util_QueryDbRuntime.getLocalStorageResources: Couldn't find Plugin $pluginName",
    );
    [||]->Pulumi.Output.make;
  };

let getStorageResources = (allQueryDbs, pluginName, queryDbName) =>
  switch (pluginName) {
  | None =>
    Util_QueryDbRuntime.getLocalStorageResources(allQueryDbs, queryDbName)
    ->Pulumi.Output.make
  | Some(pluginName) => getRemoteStorageResources(pluginName, queryDbName)
  };

let allResolversMakers = allQueryDbs =>
  allQueryDbs
  ->Js.Dict.values
  ->Belt.Array.map(queryDb => queryDb##resolversMaker);
