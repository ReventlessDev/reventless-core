let func = "Func";

let setResolversFunc = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=func,
    ~name=name->ComponentType.name(ComponentType.CommandGenerator),
    ~resource,
  );
let getResolversFunc = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=func,
    ~name=name->ComponentType.name(ComponentType.CommandGenerator),
  );
