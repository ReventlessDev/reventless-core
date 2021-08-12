let storage = "Storage";

let setStorageResource = (resources, resource, name) =>
  resources->Resources.set(~adapter=storage, ~name, ~resource);
let getStorageResource = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.QueryDb),
  );
