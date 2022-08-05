let getBy:
  (array('a), 'a => Pulumi.Output.t(bool)) => Pulumi.Output.t(option('a)) =
  (resources, pred) =>
    resources->Belt.Array.reduce(
      None->Pulumi.Output.make, (supported, resource) =>
      Pulumi.Output.all2((supported, resource->pred))
      ->Pulumi.Output.apply(((acc, supported)) =>
          switch (acc) {
          | None => supported ? Some(resource) : None
          | _ => acc
          }
        )
    );

let partitionSupportedResources = (adapters, supportedServices) => {
  Js.log2("partitionSupportedResources: adapters: ", adapters);
  let (names, resourceOutputs) =
    adapters
    ->Js.Dict.entries
    ->Belt.Array.map(((name, adapter)) => {
        Js.log3(
          "partitionSupportedResources: name, adapter##resources: ",
          name,
          adapter##resources,
        );
        (
          name,
          adapter##resources
          ->getBy(resource =>
              resource##service
              ->Pulumi.Output.apply(service =>
                  supportedServices->Belt.Array.some(supportedService =>
                    service == supportedService
                  )
                )
            ),
        );
      })
    ->Belt.Array.unzip;

  resourceOutputs
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(resources => {
      Js.log2("partitionSupportedResources: resources: ", resources);
      let (supported, unsupported) =
        names
        ->Belt.Array.zip(resources)
        ->Belt.Array.partition(((_, resource)) =>
            resource->Belt.Option.isSome
          );
      Js.log2("partitionSupportedResources: supported: ", supported);
      Js.log2("partitionSupportedResources: unsupported: ", unsupported);
      (
        supported->Belt.Array.map(((name, resource)) =>
          (name, resource->Belt.Option.getExn)
        ),
        unsupported->Belt.Array.map(((name, _)) => name),
      );
    });
};

let partitionResourcesByService = (resources, service: string) => {
  Js.log2("partitionResourcesByService: resources: ", resources);
  let (resources, supportedOutputs) =
    resources
    ->Belt.Array.map(((name, resource)) =>
        (
          (name, resource),
          resource##service
          ->Pulumi.Output.apply(resourceService => resourceService == service),
        )
      )
    ->Belt.Array.unzip;

  supportedOutputs
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(supported => {
      let (supported, unsupported) =
        resources
        ->Belt.Array.zip(supported)
        ->Belt.Array.partition(((_, supported)) => supported);
      (supported->Belt.Array.unzip->fst, unsupported->Belt.Array.unzip->fst);
    });
};
