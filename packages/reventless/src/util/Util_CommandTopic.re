let connector = "Connector";

module Deploytime = {
  let setConnectorResource = (resource, name) =>
    Resources.Deploytime.set(
      ~adapter=connector,
      ~name=name->ComponentType.name(ComponentType.CommandTopic),
      ~resource,
    );
};

module Runtime = {
  let getConnectorResource = name =>
    Resources.Runtime.getExn(
      ~adapter=connector,
      ~name=name->ComponentType.name(ComponentType.CommandTopic),
    );
};
