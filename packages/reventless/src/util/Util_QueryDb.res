let getRemoteStorageResources = (pluginName, queryDbName) =>
  switch Util_StackRefs.get(pluginName)->Belt.Option.map(stackRef =>
    stackRef
    ->Pulumi.StackReference.requireOutput("plugin"->Pulumi.Input.make)
    ->Pulumi.Output.apply(plugin =>
      plugin["readModels"]
      ->Belt.Option.flatMap(readModels => readModels->Js.Dict.get(queryDbName))
      ->Belt.Option.map(readModel =>
        readModel["queryDb"]["resources"]->Belt.Array.map(Adapter.unwrappedOutputToResource)
      )
      ->Belt.Option.getWithDefault([])
    )
  ) {
  | Some(resources) => resources
  | None =>
    Js.log("Util_QueryDbRuntime.getLocalStorageResources: Couldn't find Plugin $pluginName")
    []->Pulumi.Output.make
  }

let getStorageResources = (allQueryDbs, pluginName, queryDbName) =>
  switch pluginName {
  | None =>
    Util_QueryDbRuntime.getLocalStorageResources(allQueryDbs, queryDbName)->Pulumi.Output.make
  | Some(pluginName) => getRemoteStorageResources(pluginName, queryDbName)
  }

let allResolversMakers = allQueryDbs =>
  allQueryDbs->Js.Dict.values->Belt.Array.map(queryDb => queryDb["resolversMaker"])
