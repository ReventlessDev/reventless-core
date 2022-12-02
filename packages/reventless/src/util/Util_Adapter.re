open ReventlessSpec.Adapter;
open Adapter;

let filterByOutput:
  (array(resource), resource => Pulumi.Output.t(bool)) =>
  Pulumi.Output.t(array(resource)) =
  (resources, pred) =>
    resources->Belt.Array.reduce([||]->Pulumi.Output.make, (acc, resource) =>
      Pulumi.Output.all2((acc, resource->pred)) // Outputs are unwrapped within Pulumi.Output.all2 !
      ->Pulumi.Output.apply(((acc, supported)) => {
          let resources =
            acc->Belt.Array.map(resource =>
              resource
              ->AdapterDeploytime.unsafeUnwrapResource
              ->Adapter.unwrappedToResource
            );

          supported ? resources->Belt.Array.concat([|resource|]) : resources;
        })
    );

let filterSupportedResources:
  (array(resource), array(string)) => Pulumi.Output.t(array(resource)) =
  (resources, supportedServices) =>
    resources->filterByOutput(resource =>
      try (
        resource##service
        ->Pulumi.Output.apply(service =>
            supportedServices->Belt.Array.some(supportedService =>
              service == supportedService
            )
          )
      ) {
      | _ =>
        let err = "Util.Adapter.filterSupportedResources failed";
        Js.log3(err, "resource:", resource);
        supportedServices
        ->Belt.Array.some(supportedService =>
            resource->AdapterDeploytime.unsafeUnwrapResource##service
            == supportedService
          )
        ->Message.log({j|Matching:|j})
        ->Pulumi.Output.make;
      }
    );

let filterSupportedUnwrappedResources:
  (array(unwrappedResource), array(string)) => array(unwrappedResource) =
  (resources, supportedServices) =>
    resources->Belt.Array.keep(resource =>
      supportedServices->Belt.Array.some(supportedService =>
        resource##service == supportedService
      )
    );

let findResource = (resources, service) =>
  resources
  ->filterSupportedResources([|service|])
  ->Pulumi.Output.apply(resources =>
      switch (resources) {
      | [||] =>
        let err = {j|Util.Adapter.findResource: Couldn't find service $service in resources: $resources|j};
        Js.log(err);
        Js.Exn.raiseError(err);
      | matching => matching[0]
      }
    )
  ->outputToResource;

let findUnwrappedResource = (resources, service) =>
  switch (resources->filterSupportedUnwrappedResources([|service|])) {
  | [||] =>
    let err = {j|Util.Adapter.findUnwrappedResource: Couldn't find service $service in resources: $resources|j};
    Js.log(err);
    Js.Exn.raiseError(err);

  | resources => resources[0]
  };

let findResourceInOutput = (resourcesOutput, service) =>
  resourcesOutput
  ->Pulumi.Output.flatMap(resources =>
      resources->filterSupportedResources([|service|])
    )
  ->resourcesOutputToResource;

let partitionSupportedResources = (adapters, supportedServices) => {
  let (names, resourceOutputs) =
    adapters
    ->Js.Dict.entries
    ->Belt.Array.map(((name, adapter)) =>
        (
          name,
          adapter##resources->filterSupportedResources(supportedServices),
        )
      )
    ->Belt.Array.unzip;

  resourceOutputs
  ->Pulumi.Output.all // Outputs are unwrapped within Pulumi.Output.all !
  ->Pulumi.Output.apply(resources => {
      let (supported, unsupported) =
        names
        ->Belt.Array.zip(resources)
        ->Belt.Array.partition(((_, resources)) =>
            resources->Belt.Array.length > 0
          );
      (
        supported->Belt.Array.map(((name, resources)) =>
          (
            name,
            resources->Belt.Array.map(AdapterDeploytime.unsafeUnwrapResource),
          )
        ),
        unsupported->Belt.Array.map(((name, _)) => name),
      );
    });
};

type unwrappedResources = array((string, array(unwrappedResource)));

let partitionUnwrappedResourcesByService:
  (unwrappedResources, string) => (unwrappedResources, unwrappedResources) =
  (resources, supportedService) =>
    resources->Belt.Array.partition(((_, resources)) =>
      resources->Belt.Array.some(resource =>
        resource##service == supportedService
      )
    );
