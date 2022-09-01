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

type resources = array((string, Reventless.Adapter.unwrappedResource));

let partitionSupportedResources:
  (Js.Dict.t(Reventless.EventTopic.outputs), array(string)) =>
  Pulumi.Output.t((resources, array(string))) =
  (adapters, supportedServices) => {
    let (names, resourceOutputs) =
      adapters
      ->Js.Dict.entries
      ->Belt.Array.map(((name, adapter)) =>
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
          )
        )
      ->Belt.Array.unzip;

    resourceOutputs
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(resources => {
        let (supported, unsupported) =
          names
          ->Belt.Array.zip(resources)
          ->Belt.Array.partition(((_, resource)) =>
              resource->Belt.Option.isSome
            );
        (
          supported->Belt.Array.map(((name, resource)) =>
            (
              name,
              resource
              ->Belt.Option.getExn
              ->Reventless.AdapterDeploytime.unsafeUnwrapResource // Outputs are unwrapped within Pulumi.Output.all
            )
          ),
          unsupported->Belt.Array.map(((name, _)) => name),
        );
      });
  };

let partitionResourcesByService: (resources, string) => (resources, resources) =
  (resources, service) =>
    resources->Belt.Array.partition(((_, resource)) =>
      resource##service == service
    );
