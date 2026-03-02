open Adapter

let filterSupportedResources = (resources, supportedServices) =>
  resources->Array.filter((resource: ReventlessInfra.Adapter.resource) =>
    supportedServices->Belt.Array.some(supportedService =>
      resource.service->Pulumi.Output.get == supportedService
    )
  )

let filterSupportedResolvedResources: (
  array<resolvedResource>,
  array<string>,
) => array<resolvedResource> = (resources, supportedServices) =>
  resources->Array.filter(resource =>
    supportedServices->Belt.Array.some(supportedService => resource.service == supportedService)
  )

let findResource = (resources, service) =>
  switch resources->filterSupportedResources([service]) {
  | [] =>
    let err = `Util.Adapter.findResource: Couldn't find service ${service} in resources: ${resources
      ->Array.map(res => res->JSON.stringifyAny->Option.getOrThrow)
      ->Array.joinUnsafe(", ")}`
    Console.log(err)
    JsError.throwWithMessage(err)
  | matching => matching->Array.getUnsafe(0)
  }

let findResolvedResource = (resources, service) =>
  switch resources->filterSupportedResolvedResources([service]) {
  | [] =>
    let err = `Util.Adapter.findResolvedResource: Couldn't find service ${service} in resources: ${resources
      ->Array.map(res => res->JSON.stringifyAny->Option.getOrThrow)
      ->Array.joinUnsafe(", ")}`
    Console.log(err)
    JsError.throwWithMessage(err)

  | resources => resources->Array.getUnsafe(0)
  }
