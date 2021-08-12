let connector = "Connector";

let setConnectorResource = (resource, name) =>
  resource->Resources.set(
    ~adapter=connector,
    ~name=name->ComponentType.name(ComponentType.CommandTopic),
  );
let getConnectorResource = name =>
  Resources.getExn(
    ~adapter=connector,
    ~name=name->ComponentType.name(ComponentType.CommandTopic),
  );
