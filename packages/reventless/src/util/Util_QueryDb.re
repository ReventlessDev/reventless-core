let storage = "Storage";

let setStorageResource = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.QueryDb),
    ~resource,
  );

let getStorageResource = (resources, pluginName, name) =>
  switch (pluginName) {
  | None =>
    resources
    ->Resources.getExn(
        ~adapter=storage,
        ~name=name->ComponentType.name(ComponentType.QueryDb),
      )
    ->Some
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
        Adapter.resource(
          ~id=queryDb->Pulumi.Output.apply(queryDb => queryDb##id),
          ~name=queryDb->Pulumi.Output.apply(queryDb => queryDb##name),
          ~urn=queryDb->Pulumi.Output.apply(queryDb => queryDb##urn),
          ~info=queryDb->Pulumi.Output.apply(queryDb => queryDb##info),
          ~service=queryDb->Pulumi.Output.apply(queryDb => queryDb##service),
        );
      })
  };

let filterQueryDbStorages = (resources, keep) =>
  resources->Resources.filter(
    ~name=ComponentType.QueryDb->ComponentType.toName,
    ~adapter=storage,
    ~keep,
  );
