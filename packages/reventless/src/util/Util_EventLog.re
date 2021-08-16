let storage = "Storage";

let setStorageResource = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.EventLog),
    ~resource,
  );
let getStorageResource = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.EventLog),
  );

let filterEventLogStorages = (resources, keep) =>
  resources->Resources.filter(
    ~name=ComponentType.EventLog->ComponentType.toName,
    ~adapter=storage,
    ~keep,
  );
