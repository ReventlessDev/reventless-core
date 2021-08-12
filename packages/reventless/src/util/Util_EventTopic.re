let publisher = "Publisher";

let setPublisherResource = (resources, resource, name) =>
  resources->Resources.set(
    ~adapter=publisher,
    ~name=name->ComponentType.name(ComponentType.EventTopic),
    ~resource,
  );
let getPublisherResource = (resources, name) =>
  resources->Resources.getExn(
    ~adapter=publisher,
    ~name=name->ComponentType.name(ComponentType.EventTopic),
  );
