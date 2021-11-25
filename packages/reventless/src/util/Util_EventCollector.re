let connector = "Connector";

let setConnectorResource = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=connector,
    ~name=name->ComponentType.name(ComponentType.EventCollector),
    ~resource,
  );
let getConnectorResource = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=connector,
    ~name=name->ComponentType.name(ComponentType.EventCollector),
  );
