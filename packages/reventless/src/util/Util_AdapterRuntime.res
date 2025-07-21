open Adapter

let filterSupportedResources = (resources, supportedServices) =>
  resources->Array.filter((resource: ReventlessSpec.Adapter.resource) =>
    supportedServices->Belt.Array.some(supportedService =>
      resource.service->Pulumi.Output.get == supportedService
    )
  )

let filterSupportedUnwrappedResources: (
  array<unwrappedResource>,
  array<string>,
) => array<unwrappedResource> = (resources, supportedServices) =>
  resources->Array.filter(resource =>
    supportedServices->Belt.Array.some(supportedService => resource.service == supportedService)
  )

let findResource = (resources, service) =>
  switch resources->filterSupportedResources([service]) {
  | [] =>
    let err = `Util.Adapter.findResource: Couldn't find service ${service} in resources: ${resources
      ->Array.map(res => res->Js.Json.stringifyAny->Option.getExn)
      ->Js.Array2.joinWith(", ")}`
    Js.log(err)
    Js.Exn.raiseError(err)
  | matching => matching->Array.getUnsafe(0)
  }

let findUnwrappedResource = (resources, service) =>
  switch resources->filterSupportedUnwrappedResources([service]) {
  | [] =>
    let err = `Util.Adapter.findUnwrappedResource: Couldn't find service ${service} in resources: ${resources
      ->Array.map(res => res->Js.Json.stringifyAny->Option.getExn)
      ->Js.Array2.joinWith(", ")}`
    Js.log(err)
    Js.Exn.raiseError(err)

  | resources => resources->Array.getUnsafe(0)
  }
