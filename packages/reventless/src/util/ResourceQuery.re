type runtimeQueryExn = string => Adapter.resource;

type deploytimeQueryExn = string => Adapter.resource;

let unwrapResource = (resource, resourceType, name) =>
  switch (resource) {
  | Some(resource) => resource
  | None =>
    Js.Exn.raiseError(
      {j|ResourceQuery: Couldn't find $resourceType for Service/Task $name.|j},
    )
  };