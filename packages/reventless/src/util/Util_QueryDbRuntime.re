let storage = "Storage";

let getLocalStorageResource = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=storage,
    ~name=name->ComponentType.name(ComponentType.QueryDb),
  );
