open Util_QueryDbRuntime;

let setStorageResource = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.QueryDb),
    ~resource,
  );

let getStorageResource = (resources, pluginName, name) =>
  switch (pluginName) {
  | None => getLocalStorageResource(resources, name)->Some
  | Some(pluginName) =>
    Util_StackRefs.get(pluginName)
    ->Belt.Option.map(stackRef => {
        let queryDb =
          stackRef
          ->Pulumi.StackReference.requireOutput("plugin"->Pulumi.Input.wrap)
          ->Pulumi.Output.apply(plugin =>
              plugin##readModels
              ->Belt.Option.flatMap(readModels =>
                  readModels->Js.Dict.get(name)
                )
              ->Belt.Option.map(readModel => readModel##queryDb##resources[0])
              ->Belt.Option.getExn
            );
        queryDb->Adapter.unwrappedOutputToResource;
      })
  };

let filterQueryDbStorages = (resources, keep) =>
  resources->Resources.filter(
    ~name=ComponentType.QueryDb->ComponentType.toName,
    ~adapter=storage,
    ~keep,
  );
