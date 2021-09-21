let connector = "Connector";

let setConnectorResource = (resource, name) =>
  Resources.Deploytime.set(
    ~adapter=connector,
    ~name=name->ComponentType.name(ComponentType.EventCollector),
    ~resource,
  );
let getConnectorResource = name =>
  Resources.Runtime.getExn(
    ~adapter=connector,
    ~name=name->ComponentType.name(ComponentType.EventCollector),
  );
