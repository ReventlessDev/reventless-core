let storage = "Storage";

let setStorageResource = (resource, name) =>
  resource->Resources.set(~adapter=storage, ~name);
let getStorageResource = name =>
  Resources.getExn(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.QueryDb),
  );
