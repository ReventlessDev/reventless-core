open ReventlessSpec.Adapter
open Adapter

let filterSupportedResources: (
  array<resource>,
  array<string>,
) => Pulumi.Output.t<array<resource>> = (resources, supportedServices) =>
  resources
  ->Belt.Array.map(resource => resource["service"])
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(services =>
    resources
    ->Belt.Array.zip(services)
    ->Belt.Array.keep(((_resource, service)) =>
      supportedServices->Belt.Array.some(supportedService => service == supportedService)
    )
    ->Belt.Array.map(((resource, _)) => resource)
  )

let filterSupportedUnwrappedResources: (
  array<unwrappedResource>,
  array<string>,
) => array<unwrappedResource> = (resources, supportedServices) =>
  resources->Belt.Array.keep(resource =>
    supportedServices->Belt.Array.some(supportedService => resource["service"] == supportedService)
  )

let findResource = (resources, service) =>
  resources
  ->filterSupportedResources([service])
  ->Pulumi.Output.apply(resources =>
    switch resources {
    | [] =>
      let err = j`Util.Adapter.findResource: Couldn't find service $service in resources: $resources`
      Js.log(err)
      Js.Exn.raiseError(err)
    | matching => matching[0]
    }
  )
  ->outputToResource

let findUnwrappedResource = (resources, service) =>
  switch resources->filterSupportedUnwrappedResources([service]) {
  | [] =>
    let err = j`Util.Adapter.findUnwrappedResource: Couldn't find service $service in resources: $resources`
    Js.log(err)
    Js.Exn.raiseError(err)

  | resources => resources[0]
  }

let findResourceInOutput = (resourcesOutput, service) =>
  resourcesOutput
  ->Pulumi.Output.flatMap(resources => resources->filterSupportedResources([service]))
  ->resourcesOutputToResource

let partitionSupportedResources = (adapters, supportedServices) => {
  let (names, resourceOutputs) =
    adapters
    ->Js.Dict.entries
    ->Belt.Array.map(((name, adapter)) => (
      name,
      adapter["resources"]->filterSupportedResources(supportedServices),
    ))
    ->Belt.Array.unzip

  resourceOutputs // TODO: Avoid waiting for all resourceOutputs, call apply only on needed Outputs
  ->Pulumi.Output.all // Outputs are unwrapped within Pulumi.Output.all !
  ->Pulumi.Output.apply(resources => {
    let (supported, unsupported) =
      names
      ->Belt.Array.zip(resources)
      ->Belt.Array.partition(((_, resources)) => resources->Belt.Array.length > 0)
    (
      supported->Belt.Array.map(((name, resources)) => (
        name,
        resources->Belt.Array.map(AdapterDeploytime.unsafeUnwrapResource),
      )),
      unsupported->Belt.Array.map(((name, _)) => name),
    )
  })
}

type unwrappedResources = array<(string, array<unwrappedResource>)>

let partitionUnwrappedResourcesByService: (
  unwrappedResources,
  string,
) => (unwrappedResources, unwrappedResources) = (resources, supportedService) =>
  resources->Belt.Array.partition(((_, resources)) =>
    resources->Belt.Array.some(resource => resource["service"] == supportedService)
  )
