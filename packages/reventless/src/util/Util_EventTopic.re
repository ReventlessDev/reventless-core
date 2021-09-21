let publisher = "Publisher";

module Deploytime = {
  let setPublisherResource = (resource, name) =>
    Resources.Deploytime.set(
      ~adapter=publisher,
      ~name=name->ComponentType.name(ComponentType.EventTopic),
      ~resource,
    );
  let getPublisherResource = name =>
    Resources.Deploytime.getExn(
      ~adapter=publisher,
      ~name=name->ComponentType.name(ComponentType.EventTopic),
    );
};
