open Adapter

let filterSupportedResources = (resources, supportedServices) =>
  resources->Belt.Array.keep(resource =>
    supportedServices->Belt.Array.some(supportedService =>
      resource["service"]->Pulumi.Output.get == supportedService
    )
  )

let filterSupportedUnwrappedResources: (
  array<unwrappedResource>,
  array<string>,
) => array<unwrappedResource> = (resources, supportedServices) =>
  resources->Belt.Array.keep(resource =>
    supportedServices->Belt.Array.some(supportedService => resource["service"] == supportedService)
  )

let findResource = (resources, service) =>
  switch resources->filterSupportedResources([service]) {
  | [] =>
    let err = j`Util.Adapter.findResource: Couldn't find service $service in resources: $resources`
    Js.log(err)
    Js.Exn.raiseError(err)
  | matching => matching[0]
  }

let findUnwrappedResource = (resources, service) =>
  switch resources->filterSupportedUnwrappedResources([service]) {
  | [] =>
    let err = j`Util.Adapter.findUnwrappedResource: Couldn't find service $service in resources: $resources`
    Js.log(err)
    Js.Exn.raiseError(err)

  | resources => resources[0]
  }
