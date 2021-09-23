let storage = "Storage";

module Deploytime = {
  let setStorageResource = (resource, name) =>
    Resources.Deploytime.set(
      ~adapter=storage,
      ~name=name->ComponentType.name(ComponentType.EventLog),
      ~resource,
    );

  let getStorageResource = name =>
    Resources.Deploytime.getExn(
      ~adapter=storage,
      ~name=name->ComponentType.name(ComponentType.EventLog),
    );

  let filterEventLogStorages = keep =>
    Resources.Deploytime.filter(
      ~name=ComponentType.EventLog->ComponentType.toName,
      ~adapter=storage,
      ~keep,
    );
};

module Runtime = {
  let getStorageResource = name =>
    Resources.Runtime.getExn(
      ~adapter=storage,
      ~name=name->ComponentType.name(ComponentType.EventLog),
    );

  let filterEventLogStorages = keep =>
    Resources.Runtime.filter(
      ~name=ComponentType.EventLog->ComponentType.toName,
      ~adapter=storage,
      ~keep,
    );
};
