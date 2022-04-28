let storage = "Storage";

let setStorageResource = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.QueryDb),
    ~resource,
  );
let getStorageResource = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.QueryDb),
  );

let filterQueryDbStorages = (resources, keep) =>
  resources->Resources.filter(
    ~name=ComponentType.QueryDb->ComponentType.toName,
    ~adapter=storage,
    ~keep,
  );
