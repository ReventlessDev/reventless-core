let partitionSupportedResources = (adapters, supportedServices) => {
  let (supported, unsupported) =
    adapters
    ->Js.Dict.entries
    ->Belt.Array.map(((name, adapter)) =>
        (
          name,
          adapter##resources
          ->Belt.Array.getBy(resource =>
              supportedServices->Belt.Array.some(supportedService =>
                resource##service == supportedService
              )
            ),
        )
      )
    ->Belt.Array.partition(((_, resource)) => resource->Belt.Option.isSome);
  (
    supported->Belt.Array.map(((name, resource)) =>
      (name, resource->Belt.Option.getExn)
    ),
    unsupported->Belt.Array.map(((name, _)) => name),
  );
};

let partitionResourcesByService = (resources, service) =>
  resources->Belt.Array.partition(((_, resource)) =>
    resource##service == service
  );
