let publisher = "Publisher";

let setPublisherResource = (resource, name) =>
  resource->Resources.set(
    ~adapter=publisher,
    ~name=name->ComponentType.name(ComponentType.EventTopic),
  );
let getPublisherResource = name =>
  Resources.getExn(
    ~adapter=publisher,
    ~name=name->ComponentType.name(ComponentType.EventTopic),
  );
