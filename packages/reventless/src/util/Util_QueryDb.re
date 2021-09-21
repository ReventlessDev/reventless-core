let storage = "Storage";

module Deploytime = {
  let setStorageResource = (resource, name) =>
    Resources.Deploytime.set(~adapter=storage, ~name, ~resource);
  let getStorageResource = name =>
    Resources.Deploytime.getExn(
      ~adapter=storage,
      ~name=name->ComponentType.name(ComponentType.QueryDb),
    );
};
module Runtime = {
  let getStorageResource = name =>
    Resources.Runtime.getExn(
      ~adapter=storage,
      ~name=name->ComponentType.name(ComponentType.QueryDb),
    );

  let filterQueryDbStorages = keep =>
    Resources.Runtime.filter(
      ~name=ComponentType.QueryDb->ComponentType.toName,
      ~adapter=storage,
      ~keep,
    );
};
