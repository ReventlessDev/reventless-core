let func = "Func";

let setHandlerFunc = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=func,
    ~name=name->ComponentType.name(ComponentType.Counter),
    ~resource,
  );
let getHandlerFunc = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=func,
    ~name=name->ComponentType.name(ComponentType.Counter),
  );
